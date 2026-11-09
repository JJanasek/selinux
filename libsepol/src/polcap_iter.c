#include <sepol/polcap.h>

#include <sepol/policydb/ebitmap.h>
#include <sepol/policydb/polcaps.h>
#include <sepol/policydb/policydb.h>
#include <stddef.h>
#include <stdlib.h>

#include "debug.h"

struct sepol_polcap_iter {
	const ebitmap_t *caps;
	ebitmap_node_t *node;
	uint32_t bit;
	uint32_t highbit;
	size_t count;
};

int sepol_polcap_iter_create(sepol_handle_t *handle, const sepol_policydb_t *p,
			     sepol_polcap_iter_t **iter)
{
	if (!iter)
		return STATUS_ERR;
	if (!p) {
		*iter = NULL;
		return STATUS_ERR;
	}

	sepol_polcap_iter_t *tmp = malloc(sizeof(*tmp));
	if (!tmp) {
		ERR(handle, "out of memory");
		*iter = NULL;
		return STATUS_ERR;
	}

	tmp->caps = &p->p.policycaps;
	tmp->bit = ebitmap_start(tmp->caps, &tmp->node);
	tmp->highbit = ebitmap_length(tmp->caps);

	tmp->count = 0;
	{
		ebitmap_node_t *n;
		uint32_t bit;
		ebitmap_for_each_positive_bit(tmp->caps, n, bit)
			tmp->count++;
	}

	*iter = tmp;
	return STATUS_SUCCESS;
}

void sepol_polcap_iter_destroy(sepol_polcap_iter_t *iter)
{
	free(iter);
}

size_t sepol_polcap_iter_get_count(const sepol_polcap_iter_t *iter)
{
	if (!iter)
		return 0;
	return iter->count;
}

int sepol_polcap_iter_next(sepol_handle_t *handle __attribute__((unused)),
			   sepol_polcap_iter_t *iter, uint32_t *cap_num,
			   const char **cap_name, int *has_next)
{
	if (!iter || !cap_num || !cap_name || !has_next)
		return STATUS_ERR;

	if (!ebitmap_find_next_set_bit(&iter->node, &iter->bit,
				       iter->highbit)) {
		*has_next = 0;
		return STATUS_SUCCESS;
	}

	*cap_num = iter->bit;
	*cap_name = sepol_polcap_getname(iter->bit);
	*has_next = 1;

	iter->bit = ebitmap_next(&iter->node, iter->bit);

	return STATUS_SUCCESS;
}
