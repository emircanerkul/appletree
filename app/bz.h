// C bridge to the appletree Rust scan engine.
#ifndef BZ_H
#define BZ_H

#include <stdint.h>
#include <removefile.h> // removefile / REMOVEFILE_RECURSIVE, used by Swift

typedef struct BzScan BzScan;

BzScan *bz_scan_start(const char *path);
void bz_progress(BzScan *h, uint64_t *files, uint64_t *dirs, uint64_t *bytes, int *done);
uint64_t bz_take_tree(BzScan *h);

const uint32_t *bz_parents(BzScan *h);
const uint64_t *bz_alloc(BzScan *h);
const uint64_t *bz_logical(BzScan *h);
const uint32_t *bz_nfiles(BzScan *h);
const uint8_t *bz_flags(BzScan *h); // bit0 = is_dir
const uint32_t *bz_child_off(BzScan *h); // length N+1
const uint32_t *bz_children(BzScan *h);
const uint32_t *bz_name_off(BzScan *h); // length N+1
const uint8_t *bz_name_blob(BzScan *h);
uint64_t bz_errors(BzScan *h);

// Shared Clean Up results, sorted by size. Buffers/labels live until bz_free.
// Only read cleanup_nodes[0..cleanup_count]; an empty list has count zero.
uint64_t bz_cleanup_count(BzScan *h);
const uint32_t *bz_cleanup_nodes(BzScan *h);
// index is a candidate-list index, not a tree node index. NULL out of range.
const char *bz_cleanup_description(BzScan *h, uint64_t index);
// The tool that owns candidate `index` (uv, Cargo, pnpm, pip, Homebrew, …), or
// an empty string when the candidate was recognised by shape rather than by a
// CACHE_RULES row. Same indexing contract and lifetime as the description.
const char *bz_cleanup_tool(BzScan *h, uint64_t index);

// The only cleanup commands AppleTree may run (S6), single source of truth.
// Static data: valid for the program's lifetime, never freed. Read
// allowlist[0..allowlist_count]; entries are NUL-terminated `char *`.
const char *const *bz_cleanup_allowlist(void);
uint64_t bz_cleanup_allowlist_count(void);

// Resolve an absolute path to its tree node index; u64::MAX = not found.
// Contract: `path` is already NSString-normalized and scan-root-prefixed by
// the Swift caller, INCLUDING the "/System/Volumes/Data" root-refix (it stays
// a Swift-side pre-check; the engine only takes the final, refixed path).
// A path equal to the root's own name resolves to node 0; a missing
// component returns u64::MAX. The path pointer is only read during the call.
// Null path or a handle whose scan has not finished (no flat tree) also
// returns u64::MAX; `h` must remain valid for the duration of the call.
uint64_t bz_node_at_path(BzScan *h, const char *path);

void bz_free(BzScan *h);

// Drop `node`'s subtree from the finished tree, in place, after its path left
// the scan root. Returns 1 on success; 0 for the root, an out-of-range index, a
// node already removed, or a handle whose scan has not finished.
//
// No Vec is reallocated, so every pointer a bz_* getter returned stays valid,
// and no node is renumbered, so ids the Swift side holds (zoom, selection,
// hover, plan cards) keep naming the same folders. Clean Up's candidate list IS
// recomputed and may be reallocated, so read it through bz_cleanup_nodes /
// bz_cleanup_count rather than caching either.
int bz_remove_node(BzScan *h, uint64_t node);

#endif
