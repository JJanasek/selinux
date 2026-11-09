#ifndef _SEPOL_POLCAP_H_
#define _SEPOL_POLCAP_H_

#include <sepol/handle.h>
#include <sepol/policydb.h>
#include <sepol/policydb/polcaps.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sepol_polcap_iter sepol_polcap_iter_t;

extern int sepol_polcap_iter_create(sepol_handle_t *handle,
				    const sepol_policydb_t *p,
				    sepol_polcap_iter_t **iter);

extern void sepol_polcap_iter_destroy(sepol_polcap_iter_t *iter);

/* O(1) snapshot taken at *_create(); not refreshed if the policydb mutates. NULL iter returns 0. */
extern size_t sepol_polcap_iter_get_count(const sepol_polcap_iter_t *iter);

/*
 * Exhaustion: on success, *_next() returns 0. *has_next is set to 1 when
 * a capability was produced (*cap_num is a 0-based POLICYDB_CAP_* number
 * and *cap_name its string name), or 0 when the iterator is exhausted
 * (*cap_num / *cap_name are left unspecified). Returns non-zero on
 * error. Note that 0 is a valid capability number, so exhaustion must
 * be detected via *has_next, not via *cap_num.
 */
extern int sepol_polcap_iter_next(sepol_handle_t *handle,
				  sepol_polcap_iter_t *iter, uint32_t *cap_num,
				  const char **cap_name, int *has_next);

/*
 * sepol_polcap_getnum()/sepol_polcap_getname() are declared by
 * <sepol/policydb/polcaps.h>, included above.
 */

#ifdef __cplusplus
}
#endif

#endif
