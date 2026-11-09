#ifndef _SEPOL_PERMISSIVE_H_
#define _SEPOL_PERMISSIVE_H_

#include <sepol/handle.h>
#include <sepol/policydb.h>
#include <stdint.h>
#include <stddef.h>

#ifdef __cplusplus
extern "C" {
#endif

typedef struct sepol_permissive_iter sepol_permissive_iter_t;

extern int sepol_permissive_iter_create(sepol_handle_t *handle,
					const sepol_policydb_t *p,
					sepol_permissive_iter_t **iter);

extern void sepol_permissive_iter_destroy(sepol_permissive_iter_t *iter);

/* O(1) snapshot taken at *_create(); not refreshed if the policydb mutates. NULL iter returns 0. */
extern size_t sepol_permissive_iter_get_count(const sepol_permissive_iter_t *iter);

/*
 * Exhaustion: on success, *_next() returns 0. *has_next is set to 1 when
 * a permissive type was produced (*type_value is the 1-based type value,
 * matching sepol_type_query()/type_datum_t.s.value), or 0 when the
 * iterator is exhausted (*type_value is left unspecified). Returns
 * non-zero on error.
 */
extern int sepol_permissive_iter_next(sepol_handle_t *handle,
				      sepol_permissive_iter_t *iter,
				      uint32_t *type_value, int *has_next);

#ifdef __cplusplus
}
#endif

#endif
