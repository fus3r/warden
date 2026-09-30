self.addEventListener('push', event => {
  // Push providers receive this generic notice only; commands stay inside the encrypted connection.
  event.waitUntil(self.registration.showNotification('Warden needs you', {
    body: 'Open Warden to see what is waiting on your Mac.', icon: '/icon.png', tag: 'warden-attention',
  }));
});
self.addEventListener('notificationclick', event => {
  event.notification.close();
  event.waitUntil(clients.matchAll({ type: 'window', includeUncontrolled: true }).then(windows => {
    const existing = windows.find(window => new URL(window.url).origin === self.location.origin);
    return existing ? existing.focus() : clients.openWindow('/');
  }));
});
