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
  const left = document.getElementById("ear-l");
  const right = document.getElementById("ear-r");

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
  let angle = 35;
  let held = false;
  let hovering = false;

  const render = () => {
    source.setAttribute("transform", `rotate(${angle})`);
    const azimuth = Math.round((360 - angle) % 360) % 360;
    readout.textContent = `${azimuth}°`;
    const side = Math.sin((angle * Math.PI) / 180); // +1 is fully right
    left.style.setProperty("--level", (0.55 - 0.4 * side).toFixed(3));
    right.style.setProperty("--level", (0.55 + 0.4 * side).toFixed(3));
  };

  const follow = (event) => {
    const box = svg.getBoundingClientRect();
    const x = event.clientX - (box.left + box.width / 2);
    const y = event.clientY - (box.top + box.height / 2);
    angle = ((Math.atan2(x, -y) * 180) / Math.PI + 360) % 360;
    render();
  };

  svg.addEventListener("pointerdown", (event) => { held = true; svg.setPointerCapture(event.pointerId); follow(event); });
  svg.addEventListener("pointermove", (event) => { if (held || event.pointerType === "mouse") follow(event); });
  svg.addEventListener("pointerup", () => { held = false; });
  svg.addEventListener("pointercancel", () => { held = false; });
  svg.addEventListener("pointerenter", () => { hovering = true; });
  svg.addEventListener("pointerleave", () => { hovering = false; });

  let last = performance.now();
  const orbit = (now) => {
    if (!held && !hovering) { angle = (angle + ((now - last) / 1000) * 14) % 360; render(); }
    last = now;
    requestAnimationFrame(orbit);
  };
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
