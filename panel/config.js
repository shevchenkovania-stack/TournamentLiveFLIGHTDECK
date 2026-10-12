// Optional runtime overrides for the cockpit.
// Locally you can leave this empty — the panel defaults to :8888 on this host.
//
// On a VPS fronted by Caddy, expose the MediaMTX player on its own TLS
// subdomain (so the built-in player keeps its absolute-root asset URLs) and
// point the panel at it here, e.g.:
//
//   window.TL = {
//     playerOrigin: 'https://preview.example.com'
//   };
//
window.TL = window.TL || {};
