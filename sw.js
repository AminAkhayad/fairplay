// Minimal service worker: lets Fair Play show notifications (also as a home-screen app).
self.addEventListener('install', () => self.skipWaiting());
self.addEventListener('activate', e => e.waitUntil(self.clients.claim()));
self.addEventListener('notificationclick', e => {
  e.notification.close();
  e.waitUntil(self.clients.matchAll({type: 'window', includeUncontrolled: true})
    .then(list => list.length ? list[0].focus() : self.clients.openWindow('./')));
});
