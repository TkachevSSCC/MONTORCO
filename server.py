# -*- coding: utf-8 -*-
"""Сайт-визитка: живые показания USB CO2-монитора (Holtek USB-zyTemp, 04d9:a052).

Читает HID-отчёты напрямую, без сторонних сервисов. Поддерживает несколько
однотипных датчиков одновременно: при подключении нового он появляется на
странице автоматически.

Запуск:  python -m uvicorn server:app --host 127.0.0.1 --port 8100
"""
from __future__ import annotations

import asyncio
import json
import threading
import time
from collections import deque
from pathlib import Path

import hid
from fastapi import FastAPI, Request
from pydantic import BaseModel, Field
from fastapi.responses import FileResponse, StreamingResponse
from fastapi.staticfiles import StaticFiles

BASE_DIR = Path(__file__).resolve().parent
STATIC_DIR = BASE_DIR / "static"

VENDOR_ID = 0x04D9
PRODUCT_ID = 0xA052
MAGIC_TABLE = (0, 0, 0, 0, 0, 0, 0, 0)
# ключ расшифровки для оригинальных TFA AirCO2ntrol
MAGIC_WORD = [((w << 4) & 0xFF) | (w >> 4) for w in bytearray(b"Htemp99e")]

MAX_POINTS = 900          # ~75 минут при пакете раз в 5 секунд
STALE_AFTER = 20.0        # секунд без пакетов -> датчик считается потерянным
SCAN_EVERY = 4.0          # период поиска новых датчиков
REMOTE_STALE_AFTER = 20.0

CODE_CO2 = 0x50
CODE_TEMP = 0x42
END_MESSAGE = 0x0D


# --------------------------------------------------------------------------
# протокол
# --------------------------------------------------------------------------
def _to_int(data: list[int]) -> int:
    value = 0
    for i, byte in enumerate(reversed(data)):
        value |= byte << (i * 8)
    return value


def _to_bytes(value: int) -> list[int]:
    return [(value >> (8 * i)) & 0xFF for i in range(7, -1, -1)]


def decrypt(message: list[int]) -> list[int]:
    """Расшифровка пакета оригинальных TFA AirCO2ntrol."""
    if len(message) != 8:
        return message
    shuffled = [message[i] for i in (2, 4, 0, 7, 1, 6, 5, 3)]
    value = _to_int(shuffled)
    value = (value >> 3) | ((value << 61) & 0xFFFFFFFFFFFFFFFF)
    return [(b - mw) & 0xFF for b, mw in zip(_to_bytes(value), MAGIC_WORD)]


def decode(message: list[int]) -> tuple[int | None, float | None]:
    """Разбор пакета: (CO2 ppm, температура °C). Оба значения опциональны."""
    if len(message) < 8:
        return None, None
    # хвост пакета: 0x0D и три нуля, затем контрольная сумма
    if message[4] != END_MESSAGE or message[5] or message[6] or message[7]:
        return None, None
    if (sum(message[:3]) & 0xFF) != message[3]:
        return None, None

    value = (message[1] << 8) | message[2]
    if message[0] == CODE_CO2:
        return int(value), None
    if message[0] == CODE_TEMP:
        return None, value * 0.0625 - 273.15
    return None, None


def classify(co2: int | None) -> tuple[str, str]:
    """Возвращает (код, подпись) для шкалы качества."""
    if co2 is None:
        return "unknown", "нет данных"
    if co2 < 600:
        return "excellent", "отлично"
    if co2 < 800:
        return "good", "хорошо"
    if co2 < 1000:
        return "moderate", "приемлемо"
    if co2 < 1400:
        return "poor", "душно"
    return "bad", "плохо"


# --------------------------------------------------------------------------
# один датчик
# --------------------------------------------------------------------------
class Sensor:
    def __init__(self, info: dict):
        raw_path = info.get("path", b"")
        self.id = raw_path.decode("utf-8", "replace") if isinstance(raw_path, bytes) else str(raw_path)
        self.info = {
            "manufacturer": info.get("manufacturer_string") or "—",
            "product": info.get("product_string") or "CO2 monitor",
            "serial": info.get("serial_number") or "—",
            "vid": f"{info.get('vendor_id', 0):04x}",
            "pid": f"{info.get('product_id', 0):04x}",
            "interface": info.get("interface_number", -1),
            "usage_page": info.get("usage_page", 0),
            "usage": info.get("usage", 0),
            "path": self.id,
        }

        self.lock = threading.Lock()
        self.history: deque = deque(maxlen=MAX_POINTS)
        self.co2: int | None = None
        self.temp: float | None = None
        self.last_update: float | None = None
        self.last_packet: str | None = None
        self.encoding: str | None = None
        self.packets = 0
        self.skipped = 0
        self.interval: float | None = None
        self._co2_times: deque = deque(maxlen=10)
        self._last_point = 0.0
        self.online = False
        self.error: str | None = None
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    # -- чтение ------------------------------------------------------------
    def start(self) -> None:
        self._thread = threading.Thread(target=self._run, daemon=True,
                                        name=f"co2-{self.info['product']}")
        self._thread.start()

    def stop(self) -> None:
        self._stop.set()

    def _open(self):
        device = hid.device()
        device.open_path(self.id.encode())
        try:
            device.send_feature_report(MAGIC_TABLE)
        except Exception:
            pass
        try:
            device.set_nonblocking(0)
        except Exception:
            pass
        return device

    def _run(self) -> None:
        device = None
        while not self._stop.is_set():
            if device is None:
                try:
                    device = self._open()
                    with self.lock:
                        self.online = True
                        self.error = None
                except Exception as exc:
                    with self.lock:
                        self.online = False
                        self.error = str(exc)
                    self._stop.wait(3.0)
                    continue

            try:
                raw = device.read(8, 1000)
            except Exception as exc:
                with self.lock:
                    self.online = False
                    self.error = str(exc)
                try:
                    device.close()
                except Exception:
                    pass
                device = None
                self._stop.wait(2.0)
                continue

            if raw:
                self._handle([int(b) for b in raw])
            else:
                with self.lock:
                    if self.last_update and time.time() - self.last_update > STALE_AFTER:
                        self.online = False

        if device is not None:
            try:
                device.close()
            except Exception:
                pass

    def _handle(self, raw: list[int]) -> None:
        now = time.time()
        co2, temp = decode(raw)
        encoding = "plain"
        if co2 is None and temp is None:
            co2, temp = decode(decrypt(raw))
            if co2 is not None or temp is not None:
                encoding = "encrypted"

        with self.lock:
            self.packets += 1
            self.last_packet = " ".join(f"{b:02x}" for b in raw)
            if co2 is None and temp is None:
                self.skipped += 1
                return

            self.encoding = encoding
            self.online = True
            self.error = None
            self.last_update = now

            if co2 is not None:
                self.co2 = co2
                self._co2_times.append(now)
                if len(self._co2_times) >= 2:
                    deltas = [b - a for a, b in zip(self._co2_times, list(self._co2_times)[1:])]
                    deltas.sort()
                    self.interval = round(deltas[len(deltas) // 2], 2)
            if temp is not None:
                self.temp = temp

            if now - self._last_point >= 1.0:
                self._last_point = now
                self.history.append([now, self.co2, self.temp])

    # -- снимок для API ----------------------------------------------------
    def snapshot(self) -> dict:
        with self.lock:
            co2_values = [p[1] for p in self.history if p[1] is not None]
            temp_values = [p[2] for p in self.history if p[2] is not None]
            verdict_code, verdict = classify(self.co2)
            return {
                "id": self.id,
                "meta": self.info,
                "online": self.online,
                "error": self.error,
                "encoding": self.encoding,
                "co2": self.co2,
                "temp": None if self.temp is None else round(self.temp, 2),
                "verdict": verdict,
                "verdict_code": verdict_code,
                "last_update": self.last_update,
                "packets": self.packets,
                "skipped": self.skipped,
                "interval": self.interval,
                "last_packet": self.last_packet,
                "stats": {
                    "co2_min": min(co2_values) if co2_values else None,
                    "co2_max": max(co2_values) if co2_values else None,
                    "co2_avg": round(sum(co2_values) / len(co2_values)) if co2_values else None,
                    "samples": len(co2_values),
                    "temp_min": round(min(temp_values), 2) if temp_values else None,
                    "temp_max": round(max(temp_values), 2) if temp_values else None,
                },
                "history": [[round(p[0], 3), p[1], None if p[2] is None else round(p[2], 2)]
                            for p in self.history],
            }


# --------------------------------------------------------------------------
# поиск и обслуживание датчиков
# --------------------------------------------------------------------------
class SensorManager:
    def __init__(self) -> None:
        self.sensors: dict[str, Sensor] = {}
        self.lock = threading.Lock()
        self._stop = threading.Event()
        self._thread: threading.Thread | None = None

    def start(self) -> None:
        self._scan()
        self._thread = threading.Thread(target=self._run, daemon=True, name="co2-scan")
        self._thread.start()

    def _scan(self) -> None:
        try:
            found = hid.enumerate(VENDOR_ID, PRODUCT_ID)
        except Exception:
            found = []
        with self.lock:
            for info in found:
                raw_path = info.get("path", b"")
                key = raw_path.decode("utf-8", "replace") if isinstance(raw_path, bytes) else str(raw_path)
                if key not in self.sensors:
                    sensor = Sensor(info)
                    self.sensors[key] = sensor
                    sensor.start()

    def _run(self) -> None:
        while not self._stop.is_set():
            self._scan()
            self._stop.wait(SCAN_EVERY)

    def stop(self) -> None:
        self._stop.set()
        with self.lock:
            for sensor in self.sensors.values():
                sensor.stop()

    def snapshot(self) -> dict:
        with self.lock:
            sensors = [s.snapshot() for s in self.sensors.values()]
        sensors.sort(key=lambda s: (not s["online"], s["meta"]["product"]))
        return {
            "time": time.time(),
            "count": len(sensors),
            "online": sum(1 for s in sensors if s["online"]),
            "sensors": sensors,
        }


class RemoteReading(BaseModel):
    sensor_id: str = Field(min_length=1, max_length=512)
    meta: dict = Field(default_factory=dict)
    co2: int | None = None
    temp: float | None = None
    encoding: str | None = None
    packets: int = 0
    skipped: int = 0
    interval: float | None = None
    last_packet: str | None = None
    sent_at: float | None = None
    latitude: float | None = Field(default=None, ge=-90, le=90)
    longitude: float | None = Field(default=None, ge=-180, le=180)


remote_readings: dict[str, dict] = {}
remote_lock = threading.Lock()


def remote_snapshot(item: dict) -> dict:
    online = time.time() - item["received_at"] <= REMOTE_STALE_AFTER
    co2 = item["co2"]
    verdict_code, verdict = classify(co2)
    return {
        "id": f"remote:{item['sensor_id']}",
        "meta": item["meta"],
        "online": online,
        "error": None if online else "удалённый агент не отвечает",
        "encoding": item["encoding"], "co2": co2, "temp": item["temp"],
        "verdict": verdict, "verdict_code": verdict_code,
        "last_update": item["sent_at"], "packets": item["packets"],
        "skipped": item["skipped"], "interval": item["interval"],
        "last_packet": item["last_packet"],
        "stats": {"co2_min": co2, "co2_max": co2, "co2_avg": co2,
                   "samples": 1 if co2 is not None else 0,
                   "temp_min": item["temp"], "temp_max": item["temp"]},
        "history": item["history"],
    }


manager = SensorManager()
manager.start()

app = FastAPI(title="CO2 live showcase", version="1.0.0")


@app.get("/api/state")
def api_state() -> dict:
    local = manager.snapshot()
    with remote_lock:
        remote = [remote_snapshot(item) for item in remote_readings.values()]
    sensors = local["sensors"] + remote
    sensors.sort(key=lambda sensor: (not sensor["online"], sensor["meta"]["product"]))
    return {
        "time": time.time(),
        "count": len(sensors),
        "online": sum(1 for sensor in sensors if sensor["online"]),
        "sensors": sensors,
    }


@app.post("/api/remote/reading")
def remote_reading(reading: RemoteReading) -> dict:
    now = time.time()
    with remote_lock:
        item = remote_readings.get(reading.sensor_id)
        history = item["history"] if item else []
        if reading.co2 is not None and (not history or now - history[-1][0] >= 1):
            history = (history + [[reading.sent_at or now, reading.co2, reading.temp]])[-900:]
        remote_readings[reading.sensor_id] = {
            "sensor_id": reading.sensor_id,
            "meta": {**reading.meta, "remote": True,
                     "product": reading.meta.get("product") or "CO2 monitor (remote)",
                     "latitude": reading.latitude,
                     "longitude": reading.longitude},
            "co2": reading.co2, "temp": reading.temp,
            "encoding": reading.encoding, "packets": reading.packets,
            "skipped": reading.skipped, "interval": reading.interval,
            "last_packet": reading.last_packet, "sent_at": reading.sent_at or now,
            "received_at": now, "history": history,
        }
    return {"ok": True}


@app.get("/api/stream")
async def api_stream(request: Request) -> StreamingResponse:
    async def events():
        while True:
            if await request.is_disconnected():
                break
            payload = json.dumps(api_state(), ensure_ascii=False)
            yield f"data: {payload}\n\n"
            await asyncio.sleep(1.0)

    return StreamingResponse(events(), media_type="text/event-stream",
                             headers={"Cache-Control": "no-store",
                                      "X-Accel-Buffering": "no"})


@app.get("/healthz")
def healthz() -> dict:
    snapshot = api_state()
    return {"ok": snapshot["online"] > 0, "sensors": snapshot["count"],
            "online": snapshot["online"]}


@app.get("/remote_agent.py")
def download_remote_agent() -> FileResponse:
    return FileResponse(BASE_DIR / "remote_agent.py", filename="remote_agent.py",
                        media_type="text/x-python")


@app.get("/start_agent.bat")
def download_agent_launcher() -> FileResponse:
    return FileResponse(BASE_DIR / "start_agent.bat", filename="start_agent.bat",
                        media_type="application/octet-stream")


@app.get("/")
def index() -> FileResponse:
    return FileResponse(STATIC_DIR / "index.html")


app.mount("/static", StaticFiles(directory=STATIC_DIR), name="static")
