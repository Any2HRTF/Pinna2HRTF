(() => {
  const dark = window.matchMedia('(prefers-color-scheme: dark)');
  const updateLinks = () => {
    document.querySelectorAll('a[data-dark-href]').forEach((link) => {
      link.href = dark.matches ? link.dataset.darkHref : link.dataset.lightHref;
    });
  };
  updateLinks();
  dark.addEventListener('change', updateLinks);
})();
