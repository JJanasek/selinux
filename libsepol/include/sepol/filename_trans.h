#ifndef _SEPOL_FILENAME_TRANS_H_
#define _SEPOL_FILENAME_TRANS_H_

#include <sepol/handle.h>
#include <sepol/policydb.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

struct sepol_filename_trans_iter;
typedef struct sepol_filename_trans_iter sepol_filename_trans_iter_t;

/*
 * Kernel-format only: filename_trans is populated for POLICY_KERN
 * policydbs. On a POLICY_BASE/POLICY_MOD (source/module) policydb the
 * table is empty -- filename transitions live on per-decl lists instead
 * -- so this iterator silently yields nothing. Expand/link to a kernel
 * policydb before using these iterators for analysis.
 *
 * Iteration order is unspecified (currently hash-bucket order of the
 * internal symbol table) and may change between library versions or
 * policydb loads; callers must not rely on it matching declaration order
 * or being stable across calls.
 *
 * get_count is an O(1) snapshot taken at *_create(); it is not refreshed
 * if the policydb mutates. A NULL iter returns 0.
 */
extern int sepol_filename_trans_iter_create(sepol_handle_t *handle,
					    const sepol_policydb_t *p,
					    sepol_filename_trans_iter_t **iter);

extern void
sepol_filename_trans_iter_destroy(sepol_filename_trans_iter_t *iter);

/*
 * Exhaustion: on success, *_next() returns 0. *has_next is set to 1 when
 * a filename transition was produced (type/class values are 1-based), or
 * 0 when the iterator is exhausted (value outs may be zeroed). Returns
 * non-zero on error.
 */
extern int sepol_filename_trans_iter_next(
	sepol_handle_t *handle, sepol_filename_trans_iter_t *iter,
	uint32_t *source_type, uint32_t *target_type, uint32_t *target_class,
	const char **filename, uint32_t *default_type, int *has_next);

extern size_t sepol_filename_trans_iter_get_count(const sepol_filename_trans_iter_t *iter);

#ifdef __cplusplus
}
#endif

#endif
