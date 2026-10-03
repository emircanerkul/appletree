#include "ui_fixture.h"
#include <stdlib.h>
#include <string.h>

struct BzScan {
    uint32_t count, cleanup_count;
    uint32_t *cleanup_nodes;
    char **cleanup_descriptions;
    uint32_t *parents, *nfiles, *child_off, *children, *name_off;
    uint64_t *alloc;
    uint8_t *flags, *name_blob;
};
static void *copied(const void *source, size_t bytes) {
    void *result = malloc(bytes ? bytes : 1);
    if (!result) abort();
    if (bytes) memcpy(result, source, bytes);
    return result;
}
BzScan *bz_fixture_create(uint32_t n, const uint32_t *parents,
                         const uint64_t *alloc, const uint8_t *flags,
                         const uint32_t *child_off, const uint32_t *children,
                         const uint32_t *name_off, const uint8_t *name_blob) {
    BzScan *h = calloc(1, sizeof(*h));
    if (!h) abort();
    h->count = n;
    h->cleanup_nodes = copied(NULL, 0);
    h->parents = copied(parents, n * sizeof(*parents));
    h->alloc = copied(alloc, n * sizeof(*alloc));
    h->flags = copied(flags, n * sizeof(*flags));
    h->nfiles = calloc(n, sizeof(*h->nfiles));
    h->child_off = copied(child_off, (n + 1) * sizeof(*child_off));
    h->children = copied(children, child_off[n] * sizeof(*children));
    h->name_off = copied(name_off, (n + 1) * sizeof(*name_off));
    h->name_blob = copied(name_blob, name_off[n]);
    return h;
}
BzScan *bz_scan_start(const char *path) { (void)path; abort(); }
void bz_progress(BzScan *h, uint64_t *f, uint64_t *d, uint64_t *b, int *done) {
    (void)h; *f = 0; *d = 0; *b = 0; *done = 1;
}
uint64_t bz_take_tree(BzScan *h) { return h->count; }
const uint32_t *bz_parents(BzScan *h) { return h->parents; }
const uint64_t *bz_alloc(BzScan *h) { return h->alloc; }
const uint64_t *bz_logical(BzScan *h) { return h->alloc; }
const uint32_t *bz_nfiles(BzScan *h) { return h->nfiles; }
const uint8_t *bz_flags(BzScan *h) { return h->flags; }
const uint32_t *bz_child_off(BzScan *h) { return h->child_off; }
const uint32_t *bz_children(BzScan *h) { return h->children; }
const uint32_t *bz_name_off(BzScan *h) { return h->name_off; }
const uint8_t *bz_name_blob(BzScan *h) { return h->name_blob; }
uint64_t bz_errors(BzScan *h) { (void)h; return 0; }
void bz_fixture_add_cleanup(BzScan *h, uint32_t node, const char *description) {
    uint32_t n = h->cleanup_count;
    h->cleanup_nodes = realloc(h->cleanup_nodes, (n + 1) * sizeof(*h->cleanup_nodes));
    h->cleanup_descriptions = realloc(h->cleanup_descriptions, (n + 1) * sizeof(*h->cleanup_descriptions));
    if (!h->cleanup_nodes || !h->cleanup_descriptions) abort();
    h->cleanup_nodes[n] = node;
    h->cleanup_descriptions[n] = strdup(description);
    if (!h->cleanup_descriptions[n]) abort();
    h->cleanup_count += 1;
}
uint64_t bz_cleanup_count(BzScan *h) { return h->cleanup_count; }
const uint32_t *bz_cleanup_nodes(BzScan *h) { return h->cleanup_nodes; }
const char *bz_cleanup_description(BzScan *h, uint64_t index) {
    return index < h->cleanup_count ? h->cleanup_descriptions[index] : NULL;
}

// Cleanup-command allowlist, mirrored from src/cleanup.rs ALLOWLIST (the
// single source of truth; keep in sync).
static const char *fixture_allowlist[] = {
    "uv cache clean",
    "uv cache prune",
    "bun pm cache rm",
    "npm cache clean",
    "npm cache clean --force",
    "pnpm store prune",
    "yarn cache clean",
    "brew cleanup",
    "brew cleanup --prune=all",
    "brew autoremove",
    "docker system prune",
    "docker system prune -f",
    "docker image prune",
    "docker image prune -f",
    "docker builder prune",
    "docker builder prune -f",
    "docker container prune",
    "xcrun simctl delete unavailable",
    "conda clean",
    "conda clean -a -y",
    "mamba clean",
    "pip cache purge",
    "pip3 cache purge",
    "go clean -cache",
    "go clean -modcache",
    "gem cleanup",
    "pod cache clean --all",
};
uint64_t bz_cleanup_allowlist_count(void) {
    return sizeof(fixture_allowlist) / sizeof(fixture_allowlist[0]);
}
const char *const *bz_cleanup_allowlist(void) { return fixture_allowlist; }

// Path resolution over the fixture arrays, mirroring the engine's
// bz_node_at_path contract: byte matching against the name blob, UINT64_MAX
// when any component is missing (null handle / null path too).
//
// Names are stored NUL-free, `name_off[i]..name_off[i + 1]`, exactly as the
// engine's Tree::name_bytes and every Swift fixture builder store them. An
// earlier version of this function subtracted one byte per name for a NUL
// terminator the ABI never writes, so it resolved nothing at all — not even
// the root — and no benchmark called it, which is why it went unnoticed.
uint64_t bz_node_at_path(BzScan *h, const char *path) {
    const uint64_t NOT_FOUND = UINT64_MAX;
    if (!h || !path) return NOT_FOUND;
    size_t path_len = strlen(path);
    // Node 0's name is the scanned root, and the engine strips one trailing
    // '/' like Swift path(0), so a "/" scan reads as an empty root.
    const char *root = (const char *)h->name_blob;
    size_t root_len = h->name_off[1] - h->name_off[0];
    if (root_len > 0 && root[root_len - 1] == '/') root_len -= 1;
    if (path_len == root_len && memcmp(path, root, root_len) == 0) return 0;
    if (path_len <= root_len || memcmp(path, root, root_len) != 0 ||
        path[root_len] != '/')
        return NOT_FOUND;
    uint32_t cur = 0;
    size_t i = root_len + 1;
    while (i <= path_len) {
        size_t start = i;
        while (i < path_len && path[i] != '/') i++;
        size_t len = i - start;
        if (len > 0) {
            int matched = 0;
            for (uint32_t k = h->child_off[cur]; k < h->child_off[cur + 1]; ++k) {
                uint32_t child = h->children[k];
                const char *cname = (const char *)h->name_blob + h->name_off[child];
                size_t clen = h->name_off[child + 1] - h->name_off[child];
                if (clen == len && memcmp(cname, path + start, len) == 0) {
                    cur = child; matched = 1; break;
                }
            }
            if (!matched) return NOT_FOUND;
        }
        if (i >= path_len) break;
        i++;
    }
    return cur;
}

void bz_free(BzScan *h) {
    if (!h) return;
    for (uint32_t i = 0; i < h->cleanup_count; ++i) free(h->cleanup_descriptions[i]);
    free(h->cleanup_descriptions); free(h->cleanup_nodes);
    free(h->parents); free(h->alloc); free(h->flags); free(h->nfiles);
    free(h->child_off); free(h->children); free(h->name_off); free(h->name_blob); free(h);
}
