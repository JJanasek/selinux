#ifndef _SEPOL_CAT_SET_H_
#define _SEPOL_CAT_SET_H_

#include <sepol/handle.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

/*
 * Category set iterators are not created directly. Obtain instances from
 * MLS-related APIs such as sepol_sens_iter_get_level_cat(),
 * sepol_isid_iter_get_mls_range_low_cat(), etc.
 *
 * Ownership: every function that hands out a sepol_cat_set_iter_t **
 * (throughout ocontext.h, mls_iter.h, range_trans.h, and users.h) heap
 * allocates a new, caller-owned iterator whenever it returns 0 with a
 * non-NULL *cat_iter. The caller must call sepol_cat_set_iter_destroy()
 * on it exactly once when done -- it is not borrowed from, and does not
 * alias, any other iterator or the policydb. This applies even when the
 * underlying category set is empty: *cat_iter is only left NULL on
 * success when the *outer* iterator argument (e.g. the sepol_isid_iter_t)
 * is itself NULL or already exhausted, not merely because the category
 * set has no members -- an empty set still yields a real iterator whose
 * first sepol_cat_set_iter_next() call sets *has_next to 0.
 *
 * Exhaustion: on success, *_next() returns 0. *has_next is set to 1 when
 * a category was produced (*cat_value is the 1-based category value), or
 * 0 when the iterator is exhausted (*cat_value is left unspecified).
 * Returns non-zero on error.
 */
typedef struct sepol_cat_set_iter sepol_cat_set_iter_t;

extern int sepol_cat_set_iter_next(sepol_handle_t *handle,
				   sepol_cat_set_iter_t *iter,
				   uint32_t *cat_value, int *has_next);

extern void sepol_cat_set_iter_destroy(sepol_cat_set_iter_t *iter);

/* O(1) snapshot taken at *_create(); not refreshed if the policydb mutates. NULL iter returns 0. */
extern size_t sepol_cat_set_iter_get_count(const sepol_cat_set_iter_t *iter);

#ifdef __cplusplus
}
#endif

#endif
