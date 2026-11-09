#ifndef _SEPOL_TYPES_H_
#define _SEPOL_TYPES_H_

#include <sepol/policydb.h>
#include <sepol/type_record.h>
#include <sepol/handle.h>
#include <stddef.h>
#include <stdint.h>

#ifdef __cplusplus
extern "C" {
#endif

struct sepol_type_iter;
typedef struct sepol_type_iter sepol_type_iter_t;

/* Modify the type, or add it, if the key is not found.
 * Only supported on source-format (POLICY_BASE/POLICY_MOD) policydbs,
 * where type<->attribute membership lives directly on the type_datum;
 * returns an error for a kernel-format (POLICY_KERN) policydb, since
 * that format tracks membership via derived attr_type_map/
 * type_attr_map tables that this function does not maintain. Aliases
 * (SEPOL_TYPE_ALIAS) are not supported.
 * On failure when adding a new type, the type may still have been
 * inserted into the policydb in a partially-populated state; the
 * policydb remains memory-safe to use and destroy, but should not be
 * relied upon to be fully consistent for that type. */
extern int sepol_type_modify(sepol_handle_t *handle, sepol_policydb_t *policydb,
			     const sepol_type_key_t *key,
			     const sepol_type_t *data);

/* Return the number of types */
extern int sepol_type_count(sepol_handle_t *handle, const sepol_policydb_t *p,
			    unsigned int *response);

/* Check if the specified type exists */
extern int sepol_type_exists(sepol_handle_t *handle,
			     const sepol_policydb_t *policydb,
			     const sepol_type_key_t *key, int *response);

/* Query a type - returns the type or NULL if not found.
 * The subtypes/attributes reported via sepol_type_get_subtypes() on
 * the returned record come from different sources depending on the
 * policydb's format: for source-format (POLICY_BASE/POLICY_MOD)
 * policydbs they are read directly off the type; for kernel-format
 * (POLICY_KERN) policydbs they come from the derived attr_type_map/
 * type_attr_map tables, which are only populated after loading a
 * binary policy or expanding a module (see policydb_read()/
 * expand_module()) -- a policydb that has neither happened to it
 * (e.g. one freshly created via sepol_policydb_create()) will report
 * an empty set rather than an error. */
extern int sepol_type_query(sepol_handle_t *handle, const sepol_policydb_t *p,
			    const sepol_type_key_t *key,
			    sepol_type_t **response);

/* Resolve a type value to its name.  Returns non-zero on invalid value.
 * The returned pointer is borrowed from the policydb; do not free. */
extern int sepol_type_value_to_name(sepol_handle_t *handle,
				    const sepol_policydb_t *p, uint32_t value,
				    const char **name);

/* Query a type by value - returns the type or NULL if not found */
extern int sepol_type_query_by_value(sepol_handle_t *handle,
				     const sepol_policydb_t *p, uint32_t value,
				     sepol_type_t **response);

/*
 * Iterating types. Iteration order is unspecified (currently hash-bucket
 * order of the internal symbol table) and may change between library
 * versions or policydb loads; callers must not rely on it matching
 * declaration order or being stable across calls.
 *
 * Ownership / cost: each successful sepol_type_iter_next() that produces
 * an item heap-allocates a fresh caller-owned sepol_type_t (free with
 * sepol_type_free()). Materializing a type record copies every member of
 * the type's attribute/subtype lists via strdup, which on a real
 * refpolicy can mean thousands of types times tens of attributes -- a
 * significant allocation cost for a full walk. A cheap name+value+flavor
 * iterator is intentionally not provided here and may arrive in a
 * follow-up series.
 *
 * Exhaustion: on success, *_next() returns 0 and sets *item to a new
 * record, or to NULL when the iterator is exhausted. Returns non-zero
 * on error.
 */
extern int sepol_type_iter_create(sepol_handle_t *handle,
				  const sepol_policydb_t *p,
				  sepol_type_iter_t **iter);
extern void sepol_type_iter_destroy(sepol_type_iter_t *iter);

/* O(1) snapshot taken at *_create(); not refreshed if the policydb mutates. NULL iter returns 0. */
extern size_t sepol_type_iter_get_count(const sepol_type_iter_t *iter);
extern int sepol_type_iter_next(sepol_handle_t *handle, sepol_type_iter_t *iter,
				sepol_type_t **item);

#ifdef __cplusplus
}
#endif

#endif
