'use strict';

const express = require('express');

const PORT = Number(process.env.PORT || 3000);
const BACKEND_URL = process.env.BACKEND_URL || 'http://localhost:3001';

// Global fetch (Node >= 18) keeps this dependency-free; the Elastic APM agent
// instruments it and propagates the distributed trace to the backend.
async function fetchProducts() {
  const response = await fetch(`${BACKEND_URL}/products`);

  if (!response.ok) {
    throw new Error(`backend responded ${response.status}`);
  }

  return response.json();
}

function renderPage(products) {
  const rows = products
    .map((p) => `<li>${p.name} — $${p.price.toFixed(2)}</li>`)
    .join('\n      ');

  return `<!doctype html>
<html lang="en">
  <head><meta charset="utf-8"><title>eshop</title></head>
  <body>
    <h1>eshop</h1>
    <ul>
      ${rows}
    </ul>
  </body>
</html>`;
}

const app = express();

app.get('/healthz', (req, res) => {
  res.json({ ok: true });
});

app.get('/api/products', async (req, res) => {
  try {
    res.json(await fetchProducts());
  } catch (err) {
    console.error('failed to load products:', err.message);
    res.status(502).json({ error: 'backend unavailable' });
  }
});

app.get('/', async (req, res) => {
  try {
    res.type('html').send(renderPage(await fetchProducts()));
  } catch (err) {
    console.error('failed to load products:', err.message);
    res.status(502).type('html').send('<h1>eshop</h1><p>backend unavailable</p>');
  }
});

app.listen(PORT, () => {
  console.log(`frontend listening on :${PORT}, backend at ${BACKEND_URL}`);
});
