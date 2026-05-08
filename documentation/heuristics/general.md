# Domain Classification & Lifecycle Heuristics

## Lifecycle States

| State | Color | Description |
| :--- | :--- | :--- |
| `Priority` | Teal | High-value production domains. |
| `Active` | Green | General active production assets. |
| `Under review` | Yellow | Assets requiring validation or security cleanup. |
| `Placeholder` | Violet | Parking pages or empty indices. |
| `Insecure HTTP` | Amber | Assets lacking TLS/SSL. |
| `Redirect` | Cyan | Assets pointing elsewhere. |
| `Deprecated` | Orange | Assets scheduled for decommissioning. |
| `Decommissioned` | Red | Fully offline/removed assets. |
| `Error` | Red | Connection failures or NXDOMAIN. |
| `Abandoned` | Grey | No owner or active purpose identified. |

## HTTP Classification Logic

The system automatically suggests a classification based on `domain_metadata`:

- **200 OK**:
  - `External Redirect`: Final URL points to a different root domain.
  - `OK`: Stays on the same domain/subdomain tree.
- **3xx Redirect**: Classified as `Redirect` with target URL.
- **4xx Error**: Classified as `Client Error` (e.g., 403 Forbidden, 404 Not Found).
- **5xx Error**: Classified as `Server Error`.
- **0 / NXDOMAIN**: Classified as `Scan Error`.

## Subdomain Discovery Chain

Discovery follows a tiered API approach to minimize cost and maximize coverage:
1.  **Chaos (ProjectDiscovery)**: Fastest for known assets.
2.  **HackerTarget**: Reliable fallback for public surfaces.
3.  **crt.sh**: Certificate transparency logs for deep discovery.
