// Service worker: shows Fair Play notifications, also when the app is closed (push).
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));

self.addEventListener('push', e => {
  let d = {};
  try { d = e.data ? e.data.json() : {}; } catch (err) { d = { body: e.data && e.data.text() }; }
  e.waitUntil(self.registration.showNotification(d.title || 'Fair Play', {
    body: d.body || '',
    tag: d.tag,                    // same tag as in-app notifications, so a message never shows twice
    renotify: !!d.tag,
    icon: 'apple-touch-icon.png',
    badge: 'favicon-32.png',
    vibrate: [120, 60, 120],
    data: { url: './' },
  }));
});

self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({ type: 'window', includeUncontrolled: true })
    .then(list => list.length ? list[0].focus() : self.clients.openWindow('./')));
});
