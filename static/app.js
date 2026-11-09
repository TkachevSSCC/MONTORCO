/* Сайт-визитка CO₂: отрисовка живых данных с /api/stream */
(() => {
  "use strict";

  const $ = (id) => document.getElementById(id);

  const el = {
    conn: $("conn"),
    co2: $("co2-value"),
    temp: $("temp-value"),
    interval: $("interval-value"),
    packets: $("packets-value"),
    verdict: $("verdict"),
    reading: $("reading-card"),
    deviceName: $("device-name"),
    deviceSerial: $("device-serial"),
    deviceLink: $("device-link"),
    gaugeMarker: $("gauge-marker"),
    gaugeNote: $("gauge-note"),
    chart: $("chart"),
    chartNote: $("chart-note"),
    chartStats: $("chart-stats"),
    chartEmpty: $("chart-empty"),
    periodButtons: document.querySelectorAll(".period-button"),
    sensors: $("sensors"),
    sensorsNote: $("sensors-note"),
    telemetry: $("telemetry"),
  };

  let state = null;
  let primary = null;
  let chartHistory = [];
  let historySensorId = null;
  let chartPeriod = 86400;

  // ───────────────────────── форматирование ─────────────────────────
  const nf = new Intl.NumberFormat("ru-RU");

  const fmtInt = (v) => (v === null || v === undefined ? "—" : nf.format(Math.round(v)));
  const fmtTemp = (v) => (v === null || v === undefined ? "—" : `${v.toFixed(1)} °C`);
  const fmtSec = (v) => (v === null || v === undefined ? "—" : `${v.toFixed(1)} с`);
  const periodLabel = (seconds) => seconds >= 86400 ? "24 часа" : `${seconds / 3600} ч`;

  function ago(ts) {
    if (!ts) return "—";
    const s = Math.max(0, Math.round(Date.now() / 1000 - ts));
    if (s < 2) return "только что";
    if (s < 60) return `${s} с назад`;
    if (s < 3600) return `${Math.round(s / 60)} мин назад`;
    return `${Math.round(s / 3600)} ч назад`;
  }

  function hhmm(ts) {
    const d = new Date(ts * 1000);
    return `${String(d.getHours()).padStart(2, "0")}:${String(d.getMinutes()).padStart(2, "0")}`;
  }

  // ───────────────────────── выбор датчика ─────────────────────────
  function pickPrimary(snapshot) {
    if (!snapshot || !snapshot.sensors.length) return null;
    return snapshot.sensors.find((s) => s.online) || snapshot.sensors[0];
  }

  // ───────────────────────── верхний блок ─────────────────────────
  function renderHero() {
    if (!primary) {
      el.co2.textContent = "—";
      el.temp.textContent = "—";
      el.interval.textContent = "—";
      el.packets.textContent = "—";
      el.verdict.textContent = "датчик не найден";
      el.reading.dataset.state = "unknown";
      el.deviceName.textContent = "не подключён";
      el.deviceSerial.textContent = "—";
      el.deviceLink.textContent = "—";
      return;
    }

    const s = primary;
    el.co2.textContent = fmtInt(s.co2);
    el.temp.textContent = fmtTemp(s.temp);
    el.interval.textContent = fmtSec(s.interval);
    el.packets.textContent = fmtInt(s.packets);

    el.verdict.textContent = s.online ? s.verdict : "нет связи";
    el.reading.dataset.state = s.online ? s.verdict_code : "unknown";

    el.deviceName.textContent = s.meta.product;
    el.deviceSerial.textContent = s.meta.serial;
    el.deviceLink.textContent = `USB HID · ${s.meta.vid}:${s.meta.pid}`;
  }

  // ───────────────────────── шкала ─────────────────────────
  function renderGauge() {
    if (!primary || primary.co2 === null || primary.co2 === undefined) {
      el.gaugeMarker.hidden = true;
      el.gaugeNote.textContent = "—";
      return;
    }
    const ratio = Math.min(1, Math.max(0, (primary.co2 - 400) / 1600));
    el.gaugeMarker.hidden = false;
    el.gaugeMarker.style.left = `${(ratio * 100).toFixed(2)}%`;
    el.gaugeNote.textContent = `${fmtInt(primary.co2)} ppm · ${primary.verdict}`;
  }

  // ───────────────────────── график ─────────────────────────
  function drawChart() {
    const canvas = el.chart;
    const ctx = canvas.getContext("2d");
    const dpr = window.devicePixelRatio || 1;
    const cssW = canvas.clientWidth || 600;
    const cssH = 260;

    canvas.width = Math.round(cssW * dpr);
    canvas.height = Math.round(cssH * dpr);
    ctx.setTransform(dpr, 0, 0, dpr, 0, 0);
    ctx.clearRect(0, 0, cssW, cssH);

    const allPoints = chartHistory.filter((p) => p[1] !== null && p[1] !== undefined);
    const latest = allPoints[allPoints.length - 1]?.[0] || Date.now() / 1000;
    const periodStart = latest - chartPeriod;
    const points = allPoints.filter((p) => p[0] >= periodStart);
    el.chartEmpty.hidden = points.length >= 2;
    if (points.length < 2) {
      el.chartStats.textContent = "мин — · среднее — · макс —";
      el.chartNote.textContent = periodLabel(chartPeriod);
      return;
    }

    const padL = 46;
    const padR = 14;
    const padT = 14;
    const padB = 26;
    const plotW = cssW - padL - padR;
    const plotH = cssH - padT - padB;

    // Показываем весь доступный период, максимум последние 24 часа.
    const lastT = points[points.length - 1][0];
    const firstT = points[0][0];
    const span = Math.min(chartPeriod, Math.max(60, lastT - firstT));
    const t0 = lastT - span;

    const visible = points.filter((p) => p[0] >= t0);
    const values = visible.map((p) => p[1]);

    const rawMin = Math.min(...values);
    const rawMax = Math.max(...values);
    const yMin = Math.min(400, Math.floor((rawMin - 40) / 100) * 100);
    const yMax = Math.max(1000, Math.ceil((rawMax + 40) / 100) * 100);

    const x = (t) => padL + ((t - t0) / span) * plotW;
    const y = (v) => padT + plotH - ((v - yMin) / (yMax - yMin)) * plotH;

    // фоновые полосы качества
    const bands = [
      [400, 600, "rgba(61,220,151,0.07)"],
      [600, 800, "rgba(142,224,106,0.06)"],
      [800, 1000, "rgba(242,201,76,0.06)"],
      [1000, 1400, "rgba(255,159,67,0.07)"],
      [1400, 4000, "rgba(255,95,95,0.08)"],
    ];
    for (const [from, to, color] of bands) {
      const a = Math.max(from, yMin);
      const b = Math.min(to, yMax);
      if (b <= a) continue;
      ctx.fillStyle = color;
      ctx.fillRect(padL, y(b), plotW, y(a) - y(b));
    }

    // сетка
    ctx.strokeStyle = "rgba(139,161,174,0.14)";
    ctx.fillStyle = "#64798a";
    ctx.font = "11px 'Cascadia Mono', Consolas, monospace";
    ctx.lineWidth = 1;
    const ticks = 4;
    for (let i = 0; i <= ticks; i += 1) {
      const v = yMin + ((yMax - yMin) * i) / ticks;
      const py = Math.round(y(v)) + 0.5;
      ctx.beginPath();
      ctx.moveTo(padL, py);
      ctx.lineTo(padL + plotW, py);
      ctx.stroke();
      ctx.textAlign = "right";
      ctx.textBaseline = "middle";
      ctx.fillText(String(Math.round(v)), padL - 8, py);
    }

    // линия
    const color = primary.online ? "#3ddc97" : "#8ba1ae";

    ctx.beginPath();
    visible.forEach((p, i) => {
      const px = x(p[0]);
      const py = y(p[1]);
      if (i === 0) ctx.moveTo(px, py);
      else ctx.lineTo(px, py);
    });

    // заливка под линией
    const fill = ctx.createLinearGradient(0, padT, 0, padT + plotH);
    fill.addColorStop(0, "rgba(61,220,151,0.22)");
    fill.addColorStop(1, "rgba(61,220,151,0.0)");
    ctx.save();
    ctx.lineTo(x(visible[visible.length - 1][0]), padT + plotH);
    ctx.lineTo(x(visible[0][0]), padT + plotH);
    ctx.closePath();
    ctx.fillStyle = fill;
    ctx.fill();
    ctx.restore();

    ctx.beginPath();
    visible.forEach((p, i) => {
      const px = x(p[0]);
      const py = y(p[1]);
      if (i === 0) ctx.moveTo(px, py);
      else ctx.lineTo(px, py);
    });
    ctx.strokeStyle = color;
    ctx.lineWidth = 2;
    ctx.lineJoin = "round";
    ctx.stroke();

    // последняя точка
    const last = visible[visible.length - 1];
    ctx.beginPath();
    ctx.arc(x(last[0]), y(last[1]), 4, 0, Math.PI * 2);
    ctx.fillStyle = color;
    ctx.fill();
    ctx.beginPath();
    ctx.arc(x(last[0]), y(last[1]), 8, 0, Math.PI * 2);
    ctx.fillStyle = "rgba(61,220,151,0.16)";
    ctx.fill();

    // подписи времени
    ctx.fillStyle = "#64798a";
    ctx.font = "11px 'Cascadia Mono', Consolas, monospace";
    ctx.textBaseline = "top";
    ctx.textAlign = "left";
    ctx.fillText(hhmm(t0), padL, padT + plotH + 8);
    ctx.textAlign = "center";
    ctx.fillText(hhmm(t0 + span / 2), padL + plotW / 2, padT + plotH + 8);
    ctx.textAlign = "right";
    ctx.fillText(hhmm(lastT), padL + plotW, padT + plotH + 8);

    // подписи
    const avg = Math.round(values.reduce((a, b) => a + b, 0) / values.length);
    el.chartStats.textContent =
      `мин ${fmtInt(rawMin)} · среднее ${fmtInt(avg)} · макс ${fmtInt(rawMax)}`;
    el.chartNote.textContent = periodLabel(chartPeriod);
  }

  // ───────────────────────── список датчиков ─────────────────────────
  function renderSensors() {
    const sensors = state?.sensors || [];
    el.sensors.textContent = "";

    if (!sensors.length) {
      const empty = document.createElement("div");
      empty.className = "sensors-empty";
      empty.textContent = "Датчики не найдены. Подключите монитор USB-zyTemp.";
      el.sensors.append(empty);
      el.sensorsNote.textContent = "0 устройств";
      return;
    }

    el.sensorsNote.textContent =
      `${sensors.length} устройств${sensors.length === 1 ? "о" : ""} · ` +
      `онлайн ${sensors.filter((s) => s.online).length}`;

    for (const s of sensors) {
      const card = document.createElement("div");
      card.className = "sensor";

      const top = document.createElement("div");
      top.className = "sensor-top";

      const name = document.createElement("div");
      name.className = "sensor-name";
      name.textContent = s.meta.product;

      const st = document.createElement("div");
      st.className = `sensor-state ${s.online ? "online" : "offline"}`;
      st.textContent = s.online ? "онлайн" : "нет связи";

      top.append(name, st);

      const values = document.createElement("div");
      values.className = "sensor-values";

      const mk = (label, value) => {
        const d = document.createElement("div");
        const l = document.createElement("span");
        l.textContent = label;
        const b = document.createElement("b");
        b.textContent = value;
        d.append(l, b);
        return d;
      };

      values.append(
        mk("CO₂", s.co2 === null ? "—" : `${fmtInt(s.co2)} ppm`),
        mk("Темп.", fmtTemp(s.temp)),
      );

      const path = document.createElement("div");
      path.className = "sensor-path";
      path.textContent = `${s.meta.vid}:${s.meta.pid} · ${s.meta.serial}`;

      card.append(top, values, path);
      el.sensors.append(card);
    }
  }

  // ───────────────────────── телеметрия ─────────────────────────
  function renderTelemetry() {
    el.telemetry.textContent = "";

    if (!primary) {
      const row = document.createElement("div");
      const dt = document.createElement("dt");
      dt.textContent = "Состояние";
      const dd = document.createElement("dd");
      dd.textContent = "устройство не найдено";
      row.append(dt, dd);
      el.telemetry.append(row);
      return;
    }

    const m = primary.meta;
    const rows = [
      ["Изготовитель", m.manufacturer],
      ["Модель", m.product],
      ["Серийный номер", m.serial],
      ["VID : PID", `${m.vid} : ${m.pid}`],
      ["Интерфейс", `${m.interface}`],
      ["Usage page / usage", `${m.usage_page} / ${m.usage}`],
      ["Кодировка пакета", primary.encoding === "encrypted" ? "шифрованная" :
        primary.encoding === "plain" ? "открытая" : "—"],
      ["Последний пакет", primary.last_packet || "—"],
      ["Принято пакетов", fmtInt(primary.packets)],
      ["Служебных пакетов", fmtInt(primary.skipped)],
      ["Период опроса", fmtSec(primary.interval)],
      ["Последнее обновление", ago(primary.last_update)],
      ["Путь HID", m.path],
      ["Широта", m.latitude == null ? "—" : Number(m.latitude).toFixed(5)],
      ["Долгота", m.longitude == null ? "—" : Number(m.longitude).toFixed(5)],
    ];

    for (const [label, value] of rows) {
      const row = document.createElement("div");
      const dt = document.createElement("dt");
      dt.textContent = label;
      const dd = document.createElement("dd");
      dd.textContent = value;
      row.append(dt, dd);
      el.telemetry.append(row);
    }
  }

  // ───────────────────────── статус связи ─────────────────────────
  function renderConnection() {
    const online = state?.online ?? 0;
    const total = state?.count ?? 0;
    const text = el.conn.querySelector(".conn-text");

    el.conn.classList.remove("is-live", "is-lost");
    if (online > 0) {
      el.conn.classList.add("is-live");
      text.textContent = `live · ${online} из ${total}`;
    } else if (total > 0) {
      el.conn.classList.add("is-lost");
      text.textContent = "нет связи с датчиком";
    } else {
      el.conn.classList.add("is-lost");
      text.textContent = "датчик не найден";
    }
  }

  // ───────────────────────── общий рендер ─────────────────────────
  function mergeLiveHistory(sensor) {
    const live = sensor?.history || [];
    if (!chartHistory.length) {
      chartHistory = live.slice();
      return;
    }
    const last = chartHistory[chartHistory.length - 1]?.[0] || 0;
    chartHistory = chartHistory.concat(live.filter((point) => point[0] > last)).slice(-1800);
  }

  function loadHistory(sensor) {
    if (!sensor || historySensorId === sensor.id) return;
    historySensorId = sensor.id;
    chartHistory = sensor.history || [];
    fetch(`api/history?sensor_id=${encodeURIComponent(sensor.id)}`)
      .then((response) => response.json())
      .then((data) => {
        if (data.sensor_id !== historySensorId) return;
        chartHistory = data.history || [];
        drawChart();
      })
      .catch(() => {});
  }

  function render(snapshot) {
    state = snapshot;
    primary = pickPrimary(snapshot);
    loadHistory(primary);
    mergeLiveHistory(primary);
    renderConnection();
    renderHero();
    renderGauge();
    renderSensors();
    renderTelemetry();
    drawChart();
  }

  el.periodButtons.forEach((button) => {
    button.addEventListener("click", () => {
      chartPeriod = Number(button.dataset.period);
      el.periodButtons.forEach((item) => item.classList.toggle("is-active", item === button));
      drawChart();
    });
  });

  // ───────────────────────── поток данных ─────────────────────────
  function apply(data) {
    try {
      render(JSON.parse(data));
    } catch (e) {
      console.error("bad payload", e);
    }
  }

  fetch("api/state")
    .then((r) => r.json())
    .then(render)
    .catch(() => {});

  const source = new EventSource("api/stream");
  source.onmessage = (event) => apply(event.data);
  source.onerror = () => {
    el.conn.classList.remove("is-live");
    el.conn.classList.add("is-lost");
    el.conn.querySelector(".conn-text").textContent = "переподключение…";
  };

  // страховка: если SSE не поднялся, опрашиваем REST
  setInterval(() => {
    if (!state) {
      fetch("api/state").then((r) => r.json()).then(render).catch(() => {});
    }
  }, 3000);

  // перерисовка графика при изменении размера
  let resizeTimer = null;
  window.addEventListener("resize", () => {
    clearTimeout(resizeTimer);
    resizeTimer = setTimeout(drawChart, 150);
  });
})();
