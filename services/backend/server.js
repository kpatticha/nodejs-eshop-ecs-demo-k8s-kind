'use strict';

const express = require('express');

const PORT = Number(process.env.PORT || 3000);

const products = [
  { id: 1, name: 'Espresso Machine', price: 249.0 },
  { id: 2, name: 'Burr Grinder', price: 129.5 },
  { id: 3, name: 'Gooseneck Kettle', price: 59.0 },
  { id: 4, name: 'Pour Over Dripper', price: 24.0 },
  { id: 5, name: 'Digital Scale', price: 39.95 }
];

const app = express();

app.get('/healthz', (req, res) => {
  res.json({ ok: true });
});

app.get('/products', (req, res) => {
  res.json(products);
});

app.get('/products/:id', (req, res) => {
  const product = products.find((p) => p.id === Number(req.params.id));

  if (!product) {
    res.status(404).json({ error: 'product not found' });
    return;
  }

  res.json(product);
});

app.listen(PORT, () => {
  console.log(`backend listening on :${PORT}`);
});
