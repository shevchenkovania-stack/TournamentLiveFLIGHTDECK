// VPS cockpit override: point inline preview at the TLS preview subdomain so
// MediaMTX's built-in player keeps its absolute-root asset URLs working.
// Replace the host with your real DNS record (must match the Caddyfile block).
window.TL = {
  playerOrigin: 'https://preview.example.com'
};
