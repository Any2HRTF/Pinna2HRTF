// Front-page extras: the direction dial, the scroll-tilted screenshot,
// the pinned workflow, and the typing terminal.
const reduceMotion = window.matchMedia("(prefers-reduced-motion: reduce)").matches;

// Direction dial
(() => {
  const dial = document.getElementById("dial");
  if (!dial) return;
  const svg = dial.querySelector("svg");
  const ticks = document.getElementById("dial-ticks");
  const source = document.getElementById("dial-source");
  const readout = document.getElementById("dial-az");
  const range = document.getElementById("dial-dist");
  const left = document.getElementById("ir-l");
  const right = document.getElementById("ir-r");
  const dot = source.querySelectorAll("circle");
  const ray = source.querySelector(".ray");

  for (let deg = 0; deg < 360; deg += 10) {
    const line = document.createElementNS("http://www.w3.org/2000/svg", "line");
    const major = deg % 30 === 0;
    line.setAttribute("class", major ? "tick major" : "tick");
    line.setAttribute("y1", -240);
    line.setAttribute("y2", major ? -224 : -231);
    line.setAttribute("transform", `rotate(${deg})`);
    ticks.append(line);
  }

  // `angle` runs clockwise from the front; azimuth is reported counter-clockwise.
  // `radius` is in dial units and maps to a source distance of 0.2 m to 1 m.
  const NEAR = 85, FAR = 240, HEAD = 0.0875, SPEED = 343, WINDOW = 4, POINTS = 240;
  let angle = 35;
  let radius = FAR;
  let touched = false;
  let held = false;
  let hovering = false;

  // A rough spherical-head impulse response: the sound travels straight to an ear it can
  // see and creeps around the head to one it cannot, arriving later, weaker and duller.
  const trace = (path, distance, cosine, echo) => {
    const visible = Math.acos(HEAD / distance);
    const incidence = Math.acos(Math.min(Math.max(cosine, -1), 1));
    let length, shadow = 0;
    if (incidence <= visible) length = Math.sqrt(distance * distance + HEAD * HEAD - 2 * distance * HEAD * cosine);
    else {
      length = Math.sqrt(distance * distance - HEAD * HEAD) + HEAD * (incidence - visible);
      shadow = (incidence - visible) / (Math.PI - visible);
    }
    const arrival = (length / SPEED) * 1000; // ms
    const gain = Math.min(1, Math.sqrt(0.11 / length)) * (1 - 0.6 * shadow);
    const pitch = 3.2 - 1.7 * shadow; // kHz
    const decay = 0.26 + 0.16 * shadow; // ms
    const ring = (u) => (u < 0 ? 0 : Math.exp(-u / decay) * Math.sin(2 * Math.PI * pitch * u));
    let d = "";
    for (let i = 0; i <= POINTS; i++) {
      const u = (i / POINTS) * WINDOW - arrival;
      const value = gain * (ring(u) + 0.45 * ring(u - echo));
      d += `${i ? "L" : "M"}${i} ${(30 - value * 40).toFixed(1)}`;
    }
    path.setAttribute("d", d);
  };

  const render = () => {
    source.setAttribute("transform", `rotate(${angle})`);
    dot.forEach((circle) => circle.setAttribute("cy", -radius));
    ray.setAttribute("y2", -(radius - 18));
    const azimuth = Math.round((360 - angle) % 360) % 360;
    readout.textContent = `${azimuth}°`;
    const distance = 0.2 + (0.8 * (radius - NEAR)) / (FAR - NEAR);
    range.textContent = `${distance.toFixed(2)} m`;
    const radians = (angle * Math.PI) / 180;
    const side = Math.sin(radians); // +1 is fully right
    const echo = 0.14 + 0.06 * (1 + Math.cos(radians)); // the pinna answers differently front and back
    trace(left, distance, -side, echo);
    trace(right, distance, side, echo);
  };

  const follow = (event) => {
    const box = svg.getBoundingClientRect();
    const x = event.clientX - (box.left + box.width / 2);
    const y = event.clientY - (box.top + box.height / 2);
    angle = ((Math.atan2(x, -y) * 180) / Math.PI + 360) % 360;
    radius = Math.min(Math.max(Math.hypot(x, y) * (540 / box.width), NEAR), FAR);
    touched = true;
    render();
  };

  svg.addEventListener("pointerdown", (event) => { held = true; svg.setPointerCapture(event.pointerId); follow(event); });
  svg.addEventListener("pointermove", (event) => { if (held || event.pointerType === "mouse") follow(event); });
  svg.addEventListener("pointerup", () => { held = false; });
  svg.addEventListener("pointercancel", () => { held = false; });
  svg.addEventListener("pointerenter", () => { hovering = true; });
  svg.addEventListener("pointerleave", () => { hovering = false; });

  // Wavefronts leave the source at a steady speed. When one meets the head it bounces:
  // the echo spreads back from a mirror image of the source just inside the skull
  // (the head acts as a convex mirror), so a closer source gives quicker, stronger,
  // more tightly curved reflections.
  const rings = source.querySelectorAll(".pulse");
  const echoes = source.querySelectorAll(".echo");
  const SKULL = 50, AFTER = 95, SPREAD = (58 * Math.PI) / 180;
  let phase = 0;
  const ripple = (seconds) => {
    const gap = radius - SKULL; // source to the nearest point of the head
    const travel = gap + AFTER;
    const image = (gap * SKULL) / (2 * gap + SKULL); // depth of the mirror image
    const closeness = (FAR - radius) / (FAR - NEAR);
    phase = (phase + (seconds * 90) / travel) % 1;
    rings.forEach((ring, index) => {
      const progress = (phase + index / rings.length) % 1;
      const reached = 13 + progress * (travel - 13);
      ring.setAttribute("r", reached.toFixed(1));
      ring.style.opacity = ((1 - progress) * (0.5 + 0.5 * closeness)).toFixed(3);
      ring.style.strokeWidth = (2 + 2.5 * closeness).toFixed(2);
      const echo = echoes[index];
      const back = reached - gap;
      if (back <= 0) { echo.style.opacity = 0; return; }
      const size = image + back;
      const x = (size * Math.sin(SPREAD)).toFixed(1);
      const y = (-(SKULL - image) - size * Math.cos(SPREAD)).toFixed(1);
      echo.setAttribute("d", `M${-x} ${y}A${size.toFixed(1)} ${size.toFixed(1)} 0 0 1 ${x} ${y}`);
      echo.style.opacity = ((1 - back / AFTER) * (0.35 + 0.65 * closeness)).toFixed(3);
      echo.style.strokeWidth = (1.8 + 2.2 * closeness).toFixed(2);
    });
  };

  let last = performance.now();
  const orbit = (now) => {
    const seconds = Math.min((now - last) / 1000, 0.1);
    if (!held && !hovering) {
      angle = (angle + seconds * 14) % 360;
      // Until someone takes over, drift in and out to show that distance matters too.
      if (!touched) radius = 175 + 65 * Math.cos(now / 2600);
      render();
    }
    ripple(seconds);
    last = now;
    requestAnimationFrame(orbit);
  };
  ripple(0);
  render();
  if (!reduceMotion) requestAnimationFrame(orbit);
})();

// Screenshot tips up as it scrolls into view
(() => {
  const picture = document.querySelector(".showcase picture");
  if (!picture || reduceMotion) return;
  const update = () => {
    const box = picture.getBoundingClientRect();
    const progress = (window.innerHeight - box.top) / (window.innerHeight * 0.75);
    picture.style.setProperty("--p", Math.min(Math.max(progress, 0), 1).toFixed(3));
  };
  window.addEventListener("scroll", update, { passive: true });
  window.addEventListener("resize", update);
  update();
})();

// Pinned workflow: the screenshot follows the step in the middle of the screen
(() => {
  const steps = [...document.querySelectorAll(".flow-steps li")];
  const shots = [...document.querySelectorAll(".flow-stage picture")];
  if (!steps.length || !("IntersectionObserver" in window)) return;
  const observer = new IntersectionObserver((entries) => {
    entries.forEach((entry) => {
      if (!entry.isIntersecting) return;
      const index = steps.indexOf(entry.target);
      steps.forEach((step, i) => step.classList.toggle("is-active", i === index));
      shots.forEach((shot, i) => shot.classList.toggle("is-active", i === index));
    });
  }, { rootMargin: "-50% 0px -50% 0px" });
  steps.forEach((step) => observer.observe(step));
})();

// Terminal types its commands the first time it is seen
(() => {
  const terminal = document.getElementById("terminal");
  if (!terminal || reduceMotion || !("IntersectionObserver" in window)) return;
  const observer = new IntersectionObserver(([entry]) => {
    if (!entry.isIntersecting) return;
    terminal.classList.add("is-typing");
    observer.disconnect();
  }, { threshold: 0.6 });
  observer.observe(terminal);
})();
