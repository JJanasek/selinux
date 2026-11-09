/*
 * Authors: Chad Sellers <csellers@tresys.com>
 *          Joshua Brindle <jbrindle@tresys.com>
 *          Chris PeBenito <cpebenito@tresys.com>
 *
 * Copyright (C) 2006 Tresys Technology, LLC
 *
 *  This library is free software; you can redistribute it and/or
 *  modify it under the terms of the GNU Lesser General Public
 *  License as published by the Free Software Foundation; either
 *  version 2.1 of the License, or (at your option) any later version.
 *
 *  This library is distributed in the hope that it will be useful,
 *  but WITHOUT ANY WARRANTY; without even the implied warranty of
 *  MERCHANTABILITY or FITNESS FOR A PARTICULAR PURPOSE.  See the GNU
 *  Lesser General Public License for more details.
 *
 *  You should have received a copy of the GNU Lesser General Public
 *  License along with this library; if not, write to the Free Software
 *  Foundation, Inc., 51 Franklin St, Fifth Floor, Boston, MA  02110-1301  USA
 */

#include "test-expander-users.h"
#include "helpers.h"

#include <sepol/policydb/expand.h>
#include <sepol/policydb/link.h>
#include <sepol/policydb/policydb.h>
#include <sepol/user_record.h>
#include <sepol/users.h>
#include <CUnit/Basic.h>
#include <stdlib.h>
#include <string.h>

extern policydb_t user_expanded;
extern int mls;

static void check_user_roles(policydb_t *p, const char *user_name,
			     const char **role_names, int num_roles)
{
	user_datum_t *user;
	ebitmap_node_t *tnode;
	unsigned int i;
	int j;
	unsigned char *found; /* array of booleans of roles found */
	int extra = 0; /* number of extra roles found */

	user = (user_datum_t *)hashtab_search(p->p_users.table, user_name);
	if (!user) {
		printf("%s not found\n", user_name);
		CU_FAIL("user not found");
		return;
	}
	found = calloc(num_roles, sizeof(unsigned char));
	CU_ASSERT_FATAL(found != NULL);
	ebitmap_for_each_positive_bit(&user->roles.roles, tnode, i) {
		extra++;
		for (j = 0; j < num_roles; j++) {
			if (strcmp(role_names[j], p->p_role_val_to_name[i]) ==
			    0) {
				extra--;
				found[j] += 1;
				break;
			}
		}
	}
	for (j = 0; j < num_roles; j++) {
		if (found[j] != 1) {
			printf("role %s associated with user %s %d times\n",
			       role_names[j], user_name, found[j]);
			CU_FAIL("user mapping failure\n");
		}
	}
	free(found);
	CU_ASSERT_EQUAL(extra, 0);
}

void test_expander_user_mapping(void)
{
	const char *roles1[] = { "user_check_1_1_r", "user_check_1_2_r" };

	check_user_roles(&user_expanded, "user_check_1", roles1, 2);
}

/*
 * sepol_user_modify() must register a scope[SYM_USERS] datum for new
 * users. Without that entry, expand_module() treats the user as
 * undeclared and silently drops it.
 */
void test_user_modify_registers_scope(void)
{
	sepol_policydb_t spdb;
	policydb_t expanded;
	sepol_user_t *user = NULL;
	sepol_user_key_t *key = NULL;
	scope_datum_t *scope;
	const char *roles[] = { "user_r" };
	const char *uname = "api_added_u";

	memset(&spdb, 0, sizeof(spdb));
	CU_ASSERT_EQUAL_FATAL(test_load_policy(&spdb.p, POLICY_BASE, mls,
					       "test-expander",
					       "user-base.conf"),
			      0);

	CU_ASSERT_EQUAL_FATAL(sepol_user_create(NULL, &user), 0);
	CU_ASSERT_EQUAL_FATAL(sepol_user_set_name(NULL, user, uname), 0);
	CU_ASSERT_EQUAL_FATAL(sepol_user_set_roles(NULL, user, roles, 1), 0);
	if (mls) {
		CU_ASSERT_EQUAL_FATAL(
			sepol_user_set_mlslevel(NULL, user, "s0"), 0);
		CU_ASSERT_EQUAL_FATAL(
			sepol_user_set_mlsrange(NULL, user, "s0"), 0);
	}
	CU_ASSERT_EQUAL_FATAL(sepol_user_key_create(NULL, uname, &key), 0);
	CU_ASSERT_EQUAL_FATAL(sepol_user_modify(NULL, &spdb, key, user), 0);

	scope = hashtab_search(spdb.p.scope[SYM_USERS].table, uname);
	CU_ASSERT_PTR_NOT_NULL_FATAL(scope);
	CU_ASSERT_EQUAL(scope->scope, SCOPE_DECL);
	CU_ASSERT(scope->decl_ids_len >= 1);

	CU_ASSERT_PTR_NOT_NULL(
		hashtab_search(spdb.p.p_users.table, uname));

	CU_ASSERT_EQUAL_FATAL(policydb_init(&expanded), 0);
	CU_ASSERT_EQUAL_FATAL(link_modules(NULL, &spdb.p, NULL, 0, 0), 0);
	CU_ASSERT_EQUAL_FATAL(expand_module(NULL, &spdb.p, &expanded, 0, 0),
			      0);
	CU_ASSERT_PTR_NOT_NULL(
		hashtab_search(expanded.p_users.table, uname));

	policydb_destroy(&expanded);
	policydb_destroy(&spdb.p);
	sepol_user_key_free(key);
	sepol_user_free(user);
}
