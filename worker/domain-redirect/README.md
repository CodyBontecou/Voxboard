# Vox.md domain redirect

This Worker permanently redirects the former website hostname to the canonical Vox.md hostname while preserving paths and query strings:

```text
https://voxboard.isolated.tech/docs/?source=old
→ https://vox.isolated.tech/docs/?source=old
```

First create a proxied Cloudflare DNS record and wait for the Pages custom domain to become active:

```text
CNAME  vox  voxboard.pages.dev  (proxied, TTL auto)
```

Then deploy the redirect:

```bash
wrangler deploy --config worker/domain-redirect/wrangler.toml
```

After deployment, verify the old hostname returns a `308` for both `/` and a nested path. Keep its proxied DNS record in place so the Worker route can continue receiving migration traffic.
