#ifndef _SEPOL_ROLE_RULE_H_
#define _SEPOL_ROLE_RULE_H_

#include <sepol/handle.h>
#include <sepol/policydb.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Kernel-format only: role_allow and role_tr are populated for
 * POLICY_KERN policydbs. On a POLICY_BASE/POLICY_MOD (source/module)
 * policydb those lists are empty -- role allow/transition rules live on
 * per-decl lists instead -- so these iterators silently yield nothing.
 * Expand/link to a kernel policydb before using these iterators for
 * analysis.
 *
 * get_count is an O(1) snapshot taken at *_create(); it is not refreshed
 * if the policydb mutates. A NULL iter returns 0.
 */

typedef struct sepol_role_allow_iter sepol_role_allow_iter_t;

extern int sepol_role_allow_iter_create(sepol_handle_t *handle,
					const sepol_policydb_t *p,
					sepol_role_allow_iter_t **iter);

extern void sepol_role_allow_iter_destroy(sepol_role_allow_iter_t *iter);

extern size_t sepol_role_allow_iter_get_count(const sepol_role_allow_iter_t *iter);

/*
 * Exhaustion: on success, *_next() returns 0. *has_next is set to 1 when
 * a role-allow rule was produced (role values are 1-based), or 0 when
 * the iterator is exhausted (value outs may be zeroed). Returns
 * non-zero on error.
 */
extern int sepol_role_allow_iter_next(sepol_handle_t *handle,
				      sepol_role_allow_iter_t *iter,
				      uint32_t *role, uint32_t *new_role,
				      int *has_next);

typedef struct sepol_role_trans_iter sepol_role_trans_iter_t;

extern int sepol_role_trans_iter_create(sepol_handle_t *handle,
					const sepol_policydb_t *p,
					sepol_role_trans_iter_t **iter);

extern void sepol_role_trans_iter_destroy(sepol_role_trans_iter_t *iter);

extern size_t sepol_role_trans_iter_get_count(const sepol_role_trans_iter_t *iter);

/*
 * Exhaustion: on success, *_next() returns 0. *has_next is set to 1 when
 * a role-transition rule was produced (role/type/class values are
 * 1-based), or 0 when the iterator is exhausted (value outs may be
 * zeroed). Returns non-zero on error.
 */
extern int sepol_role_trans_iter_next(sepol_handle_t *handle,
				      sepol_role_trans_iter_t *iter,
				      uint32_t *role, uint32_t *type,
				      uint32_t *tclass, uint32_t *new_role,
				      int *has_next);

#ifdef __cplusplus
}
#endif

#endif
