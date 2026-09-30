(() => {
  const links = document.querySelectorAll('.md-typeset figure a[href]');
  if (!links.length) return;

  const viewer = document.createElement('dialog');
  viewer.className = 'warden-screenshot-viewer';
  viewer.setAttribute('aria-labelledby', 'warden-screenshot-title');
  viewer.innerHTML = `
    <div class="warden-screenshot-toolbar">
      <h2 id="warden-screenshot-title">Screenshot</h2>
      <button type="button" aria-label="Close screenshot">Close</button>
    </div>
    <img class="warden-screenshot-image" alt="">
    <p class="warden-screenshot-caption"></p>
  `;
  document.body.append(viewer);

  const image = viewer.querySelector('img');
  const caption = viewer.querySelector('p');
  let trigger;
  let pixelWidth = 0;
  const sizeImage = () => {
    // One source pixel per screen pixel; the browser's raw PNG viewer can stretch a 2x capture on Retina.
    image.style.width = `${pixelWidth / Math.max(window.devicePixelRatio, 1)}px`;
  };

  for (const link of links) {
    const thumbnail = link.querySelector('img');
    if (!thumbnail) continue;
    link.addEventListener('click', event => {
      if (event.button !== 0 || event.metaKey || event.ctrlKey || event.shiftKey || event.altKey || !thumbnail.naturalWidth) return;
      event.preventDefault();
      trigger = link;
      pixelWidth = thumbnail.naturalWidth;
      image.src = link.href;
      image.alt = thumbnail.alt;
      caption.textContent = link.closest('figure').querySelector('figcaption')?.textContent || thumbnail.alt;
      sizeImage();
      viewer.showModal();
      viewer.scrollTop = 0;
    });
  }

  viewer.querySelector('button').addEventListener('click', () => viewer.close());
  viewer.addEventListener('click', event => {
    if (event.target === viewer) viewer.close();
  });
  viewer.addEventListener('close', () => {
    image.removeAttribute('src');
    trigger?.focus();
  });
  window.addEventListener('resize', () => {
    if (viewer.open) sizeImage();
  });
})();
