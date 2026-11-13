// Add a Copy button to every code block.
document.querySelectorAll("pre").forEach((pre) => {
  const block = document.createElement("div");
  block.className = "code-block";
  pre.replaceWith(block);
  block.append(pre);

  const button = document.createElement("button");
  button.type = "button";
  button.className = "copy-button";
  button.textContent = "Copy";
  button.setAttribute("aria-label", "Copy this code");
  block.append(button);

  button.addEventListener("click", async () => {
    let label = "Copied";
    try {
      await navigator.clipboard.writeText(pre.innerText.trimEnd());
    } catch {
      label = "Select to copy";
    }
    button.textContent = label;
    window.setTimeout(() => { button.textContent = "Copy"; }, 1800);
  });
});
