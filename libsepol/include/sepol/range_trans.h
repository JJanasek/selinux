#ifndef _SEPOL_RANGE_TRANS_H_
#define _SEPOL_RANGE_TRANS_H_

#include <sepol/cat_set.h>
#include <sepol/handle.h>
#include <sepol/policydb.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * NOTE on sepol_cat_set_iter_t **cat_iter parameters below: see the
 * ownership contract documented in cat_set.h. The callee always allocates
 * a new, caller-owned iterator that must be freed with
 * sepol_cat_set_iter_destroy().
 */

typedef struct sepol_range_trans_iter sepol_range_trans_iter_t;

/*
 * Kernel-format only: range_tr is populated for POLICY_KERN policydbs.
 * On a POLICY_BASE/POLICY_MOD (source/module) policydb the table is
 * empty -- range transitions live on per-decl lists instead -- so this
 * iterator silently yields nothing. Expand/link to a kernel policydb
 * before using these iterators for analysis.
 *
 * Iteration order is unspecified (currently hash-bucket order of the
 * internal symbol table) and may change between library versions or
 * policydb loads; callers must not rely on it matching declaration order
 * or being stable across calls.
 *
 * get_count is an O(1) snapshot taken at *_create(); it is not refreshed
 * if the policydb mutates. A NULL iter returns 0.
 */
extern int sepol_range_trans_iter_create(sepol_handle_t *handle,
					 const sepol_policydb_t *p,
					 sepol_range_trans_iter_t **iter);

extern void sepol_range_trans_iter_destroy(sepol_range_trans_iter_t *iter);

extern size_t sepol_range_trans_iter_get_count(const sepol_range_trans_iter_t *iter);

/*
 * Exhaustion: on success, *_next() returns 0. *has_next is set to 1 when
 * a range transition was produced (type/class values are 1-based), or 0
 * when the iterator is exhausted (value outs may be zeroed). Returns
 * non-zero on error.
 */
extern int sepol_range_trans_iter_next(sepol_handle_t *handle,
				       sepol_range_trans_iter_t *iter,
				       uint32_t *source_type,
				       uint32_t *target_type,
				       uint32_t *target_class, int *has_next);

extern uint32_t
sepol_range_trans_iter_get_low_sens(const sepol_range_trans_iter_t *iter);
extern uint32_t
sepol_range_trans_iter_get_high_sens(const sepol_range_trans_iter_t *iter);
extern int
sepol_range_trans_iter_get_low_cat(const sepol_range_trans_iter_t *iter,
				   sepol_cat_set_iter_t **cat_iter);
extern int
sepol_range_trans_iter_get_high_cat(const sepol_range_trans_iter_t *iter,
				    sepol_cat_set_iter_t **cat_iter);

#ifdef __cplusplus
}
#endif

#endif
