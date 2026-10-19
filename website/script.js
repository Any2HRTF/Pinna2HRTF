const copyButton = document.querySelector("[data-copy]");
const copyStatus = document.querySelector(".copy-status");

const clamp = (value, min, max) => Math.min(Math.max(value, min), Math.max(min, max));

document.querySelectorAll(".draggable-sticker").forEach((sticker) => {
  const area = sticker.closest(".content-section");
  if (!area) return;

  let drag = null;

  const placeFromCurrentPosition = () => {
    const left = clamp(sticker.offsetLeft, 0, area.clientWidth - sticker.offsetWidth);
    const top = clamp(sticker.offsetTop, 0, area.clientHeight - sticker.offsetHeight);
    sticker.style.left = `${left}px`;
    sticker.style.top = `${top}px`;
    sticker.style.right = "auto";
    sticker.style.bottom = "auto";
    return { left, top };
  };

  const finishMove = () => {
    if (!drag) return;
    drag = null;
    sticker.classList.remove("is-dragging", "is-released");
    void sticker.offsetWidth;
    sticker.classList.add("is-released");
  };

  sticker.addEventListener("pointerdown", (event) => {
    if (!event.isPrimary || (event.pointerType === "mouse" && event.button !== 0)) return;
    event.preventDefault();
    sticker.classList.remove("is-released");
    const position = placeFromCurrentPosition();
    drag = { pointerId: event.pointerId, x: event.clientX, y: event.clientY, ...position };
    sticker.classList.add("is-dragging");
    sticker.setPointerCapture(event.pointerId);
  });

  sticker.addEventListener("pointermove", (event) => {
    if (!drag || drag.pointerId !== event.pointerId) return;
    const maxLeft = area.clientWidth - sticker.offsetWidth;
    const maxTop = area.clientHeight - sticker.offsetHeight;
    const left = clamp(drag.left + event.clientX - drag.x, 0, maxLeft);
    const top = clamp(drag.top + event.clientY - drag.y, 0, maxTop);
    sticker.style.left = `${left}px`;
    sticker.style.top = `${top}px`;
  });

  sticker.addEventListener("pointerup", finishMove);
  sticker.addEventListener("pointercancel", finishMove);
  sticker.addEventListener("lostpointercapture", finishMove);

  sticker.addEventListener("keydown", (event) => {
    const distance = event.shiftKey ? 2 : 10;
    const moves = {
      ArrowLeft: [-distance, 0],
      ArrowRight: [distance, 0],
      ArrowUp: [0, -distance],
      ArrowDown: [0, distance],
    };
    const move = moves[event.key];
    if (!move) return;
    event.preventDefault();
    sticker.classList.remove("is-released");
    const position = placeFromCurrentPosition();
    sticker.style.left = `${clamp(position.left + move[0], 0, area.clientWidth - sticker.offsetWidth)}px`;
    sticker.style.top = `${clamp(position.top + move[1], 0, area.clientHeight - sticker.offsetHeight)}px`;
    void sticker.offsetWidth;
    sticker.classList.add("is-released");
  });
});

copyButton?.addEventListener("click", async () => {
  const target = document.getElementById(copyButton.dataset.copy);
  if (!target || !navigator.clipboard) {
    copyStatus.textContent = "Clipboard access is unavailable in this browser.";
    return;
  }

  try {
    await navigator.clipboard.writeText(target.innerText);
    copyButton.innerHTML = 'Copied <b aria-hidden="true">✓</b>';
    copyStatus.textContent = "Setup commands copied.";
    window.setTimeout(() => {
      copyButton.innerHTML = 'Copy <b aria-hidden="true">▢</b>';
    }, 1800);
  } catch {
    copyStatus.textContent = "Could not copy. Select the commands to copy them manually.";
  }
});
