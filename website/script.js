const copyButton = document.querySelector("[data-copy]");
const copyStatus = document.querySelector(".copy-status");

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
