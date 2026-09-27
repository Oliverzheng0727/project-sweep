# Project cache rules

Project Sweep uses local, inspectable rules. It does not use AI to decide whether a file is disposable, and a name such as `temp`, `old`, or `output` is never sufficient for quick selection.

## Additional rules in 0.6.0

These rules apply only to the exact default path relative to the owning project folder. That folder must contain a readable, local `package.json` declaring the named dependency in `dependencies`, `devDependencies`, or `optionalDependencies`.

Only common registry versions, ranges, and distribution tags establish producer evidence (for example, `2.14.0`, `^15`, `>=2 <3`, `latest`, and `nextbeta`). npm aliases, local or workspace replacements, Git specifications, URLs, paths, tarballs, and unrecognized specifications keep the folder under manual review. If dependency sections disagree and any declaration uses an unsupported replacement, the rule also stays manual. The app does not resolve packages or run a package manager.

Nonempty `overrides`, `resolutions`, or `pnpm.overrides` also keep caches under manual review, including overrides for another dependency. Malformed override fields do not count as empty; valid empty objects are accepted. This conservatively avoids inferring a producer while a package manager could substitute another package.

| Producer | Default path | Cleanup impact | Reference |
| --- | --- | --- | --- |
| Next.js | `.next/cache` | Cache rebuilding can slow the next build or request; some data may need to be fetched again. | [Next.js CI build caching](https://nextjs.org/docs/app/guides/ci-build-caching) |
| Parcel | `.parcel-cache` | Parcel rebuilds its cache; the next build can be slower. | [Parcel caching](https://parceljs.org/features/development/#caching) |
| Vite | `node_modules/.vite` | Vite pre-bundles dependencies again; the next startup can be slower. | [Vite cacheDir](https://vite.dev/config/shared-options#cachedir) |

The scanner records the producer, manifest location, identification reason, and regeneration impact. Stop development servers and build tasks before cleaning a cache.

The rule does **not** promote the entire `.next` or `node_modules` folder to a cache. Custom cache locations, unrelated same-name folders, and manifests in a parent outside the selected project are not used. A nested project needs its own matching manifest; a dependency declared in the outer project is not inherited.

## Protection takes precedence

- A cache containing recognized source files or artwork at any depth requires manual review. Cache protection and storage classification share the same authored-file types, including Ruby, AVIF images, FLAC audio, and EPUB documents. In particular, Vite caches commonly contain generated JavaScript; these remain **Review**, even when their location is recognized. The scanner does not infer that JavaScript is disposable from its location.
- Git-tracked content, tool configuration and skills (including `.agents`), and **Always Keep** entries retain their protection. A parent containing protected or unavailable content cannot be selected as a whole.
- Symlinks are not followed. Document and application packages remain opaque. Unreadable or cloud-only content is not silently treated as an empty cache.
- Generic document-rendering and image-processing folders are not trusted from their names. They may contain intermediate work, original assets, or final output, so they remain subject to manual review.

Existing system-generated folder display files and Python runtime/checker cache rules remain available. The same descendant, Git, and keep protections apply to them.

## Manifest access

Only candidate cache paths trigger a manifest read. Reads are limited to 256 KiB and use the existing local-only, no-follow reader with scope, file identity, size, and modification checks. A malformed, oversized, unreadable, linked, or changing manifest supplies no cache evidence. Configuration scripts are never executed, and cloud placeholders are not downloaded.

Cleanup still uses the normal review list and execution-time validation. Ordinary project files move to the system Trash; this is not reported as immediately freed disk space.
