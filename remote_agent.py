"""Удалённый агент MONTORCO для компьютера с USB CO2-датчиком.

Запуск:
  python remote_agent.py --url https://eco.curxtor.ru/co2 \
      --sensor-path 'путь из --list'
"""
from __future__ import annotations

import argparse
import hashlib
import json
import threading
import time
from urllib.request import Request, urlopen

import hid

VENDOR_ID = 0x04D9
PRODUCT_ID = 0xA052
MAGIC_TABLE = (0, 0, 0, 0, 0, 0, 0, 0)
MAGIC_WORD = [((w << 4) & 0xFF) | (w >> 4) for w in bytearray(b"Htemp99e")]


def _to_int(data: list[int]) -> int:
    value = 0
    for byte in data:
        value = (value << 8) | byte
    return value


def _to_bytes(value: int) -> list[int]:
    return [(value >> (8 * i)) & 0xFF for i in range(7, -1, -1)]


def decrypt(message: list[int]) -> list[int]:
    shuffled = [message[i] for i in (2, 4, 0, 7, 1, 6, 5, 3)]
    value = _to_int(shuffled)
    value = (value >> 3) | ((value << 61) & 0xFFFFFFFFFFFFFFFF)
    return [(b - mw) & 0xFF for b, mw in zip(_to_bytes(value), MAGIC_WORD)]


def decode(message: list[int]) -> tuple[int | None, float | None]:
    if len(message) < 8 or message[4:] != [0x0D, 0, 0, 0]:
        return None, None
    if (sum(message[:3]) & 0xFF) != message[3]:
        return None, None
    value = (message[1] << 8) | message[2]
    if message[0] == 0x50:
        return value, None
    if message[0] == 0x42:
        return None, value * 0.0625 - 273.15
    return None, None


def devices() -> list[dict]:
    return hid.enumerate(VENDOR_ID, PRODUCT_ID)


def send(url: str, payload: dict) -> None:
    request = Request(
        f"{url.rstrip('/')}/api/remote/reading",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    with urlopen(request, timeout=10) as response:
        if response.status != 200:
            raise RuntimeError(f"server returned HTTP {response.status}")


def run_device(args: argparse.Namespace, info: dict) -> None:
    path = info.get("path", b"")
    raw_path = path.decode("utf-8", "replace") if isinstance(path, bytes) else str(path)
    path_hash = hashlib.sha256(raw_path.encode()).hexdigest().upper()
    sensor_id = f"sensor-{path_hash[:16].lower()}"
    display_name = f"CO₂ датчик {path_hash[:6]}"
    meta = {
        "name": display_name,
        "manufacturer": info.get("manufacturer_string"),
        "product": info.get("product_string") or "CO2 monitor",
        "serial": "—",
        "vid": f"{info.get('vendor_id', VENDOR_ID):04x}",
        "pid": f"{info.get('product_id', PRODUCT_ID):04x}",
        "interface": info.get("interface_number", -1),
        "usage_page": info.get("usage_page", 0),
        "usage": info.get("usage", 0),
        "path": "remote agent",
        "latitude": args.latitude,
        "longitude": args.longitude,
    }
    device = hid.device()
    device.open_path(path)
    try:
        try:
            device.send_feature_report(MAGIC_TABLE)
        except Exception:
            pass
        device.set_nonblocking(0)
        co2 = None
        temp = None
        packets = 0
        skipped = 0
        last_packet = None
        last_co2_at = None
        interval = None
        last_send = 0.0
        while True:
            raw = device.read(8, 1000)
            if raw:
                raw = [int(byte) for byte in raw]
                packets += 1
                last_packet = " ".join(f"{byte:02x}" for byte in raw)
                current_co2, current_temp = decode(raw)
                encoding = "plain"
                if current_co2 is None and current_temp is None:
                    current_co2, current_temp = decode(decrypt(raw))
                    encoding = "encrypted"
                if current_co2 is None and current_temp is None:
                    skipped += 1
                else:
                    now = time.time()
                    if current_co2 is not None:
                        if last_co2_at is not None:
                            interval = round(now - last_co2_at, 2)
                        last_co2_at = now
                        co2 = current_co2
                    if current_temp is not None:
                        temp = round(current_temp, 2)
                if time.time() - last_send >= 1.0:
                    try:
                        send(args.url, {
                            "sensor_id": sensor_id,
                            "meta": meta,
                            "co2": co2,
                            "temp": temp,
                            "encoding": encoding,
                            "packets": packets,
                            "skipped": skipped,
                            "interval": interval,
                            "last_packet": last_packet,
                            "sent_at": time.time(),
                        })
                        last_send = time.time()
                        print(f"{display_name}: CO2={co2} ppm, temp={temp} C", flush=True)
                    except Exception as exc:
                        print(f"Сервер недоступен; повторю отправку: {exc}", flush=True)
                        time.sleep(2)
    finally:
        device.close()


def run(args: argparse.Namespace) -> None:
    found = devices()
    while not found:
        print("Датчик не найден; повторный поиск через 4 секунды...", flush=True)
        time.sleep(4)
        found = devices()

    if args.sensor_path:
        selected = [item for item in found if args.sensor_path in str(item.get("path", ""))]
        if not selected:
            raise SystemExit(f"Датчик с путём {args.sensor_path!r} не найден.")
        selected = selected[:1]
    else:
        selected = found

    workers = []
    for info in selected:
        worker = threading.Thread(target=run_device, args=(args, info), daemon=True)
        worker.start()
        workers.append(worker)
    for worker in workers:
        worker.join()


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--url", default="https://eco.curxtor.ru/co2")
    parser.add_argument("--sensor-path", default="")
    parser.add_argument("--latitude", type=float)
    parser.add_argument("--longitude", type=float)
    parser.add_argument("--list", action="store_true", dest="list_devices")
    args = parser.parse_args()
    found = devices()
    if args.list_devices:
        for item in found:
            print(json.dumps(item, ensure_ascii=False, default=lambda value: value.decode(errors="replace")))
        return
    run(args)


if __name__ == "__main__":
    main()
