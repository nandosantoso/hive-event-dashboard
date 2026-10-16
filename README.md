# HIVE Event Dashboard

Reusable event operations dashboard template. Create an event workspace from the app and use the same sections for each event.

## Run locally

Open `index.html` in a modern browser. On first use, create the initial administrator account in that browser.

## Data and access

This static version stores event data, accounts, sessions, and audit history in that browser's `localStorage`. It does not provide secure server-side authentication, shared multi-user storage, or cross-device synchronization. Do not use it for sensitive information until a backend is connected.

## GitHub Pages

The included Pages workflow publishes only the app files (`index.html`, `app.js`, and the CSS files). It excludes project sources and local workspace instructions. GitHub Pages sites are public, so any event data embedded in `app.js` is publicly readable in the deployed site and repository.
