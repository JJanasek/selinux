#include "test-iter-classes.h"

#include <CUnit/CUnit.h>
#include <stdbool.h>
#include <stdlib.h>
#include <string.h>

#include <sepol/policydb.h>
#include <sepol/class_record.h>
#include <sepol/classes.h>
#include <sepol/policydb/constraint.h>
#include <sepol/policydb/hashtab.h>
#include <sepol/policydb/policydb.h>
#include <sepol/policydb/symtab.h>

#include "helpers.h"

extern sepol_handle_t *handle;
extern sepol_policydb_t *empty_policy;
extern sepol_policydb_t *iter_policy;
extern int mls;

/*
 * CLASS1's constraints, from policies/test-iter/iter.conf:
 *
 *   constrain CLASS1 { PERM1 } ( t1 == { TYPE1 } );
 *   constrain CLASS1 { PERM1 } ( ( r1 == ROLE1 ) or ( u2 == USER1 ) );
 *   mlsconstrain CLASS1 { PERM1 } ( h1 dom h2 );   -- MLS builds only
 *
 * The middle constraint's expression is a boolean combination (`or`),
 * which is represented as multiple constraint_expr nodes in an
 * unspecified (postfix) order, so it is not practical to assert its
 * exact expression list here. Instead, verify_class1_constraints()
 * below checks the one property shared by every CLASS1 constraint
 * (permissions == {PERM1}) plus the exact expression contents of the
 * single unambiguous, single-expression constraint (`t1 == TYPE1`).
 */

struct expected_class {
	int seen;

	const char *name;
	const char *common;
	uint32_t nperms;
	const char *perms[32];
	char default_user;
	char default_role;
	char default_type;
	char default_range;
};

struct expected_class expected_classes[] = {
	{ 0, "CLASS1",  "COMMON1", 2, { "PERM1", "ioctl" }, 0, 0, 0, 0 },
	{ 0, "CLASS01", NULL, 1, { "PERM01" }, 0, 0, 0, 0 },
	{ 0, "CLASS02", NULL, 1, { "PERM02" }, 0, 0, 0, 0 },
	{ 0, "CLASS03", NULL, 1, { "PERM03" }, 0, 0, 0, 0 },
	{ 0, "CLASS04", NULL, 1, { "PERM04" }, 0, 0, 0, 0 },
	{ 0, "CLASS05", NULL, 1, { "PERM05" }, 0, 0, 0, 0 },
	{ 0, "CLASS06", NULL, 1, { "PERM06" }, 0, 0, 0, 0 },
	{ 0, NULL,      NULL, 0, { NULL },     0, 0, 0, 0 },
};

static void verify_class1_constraints(const sepol_constraint_t **constraints,
				      uint32_t nconstraints)
{
	int found_type_names_constraint = 0;

	/* Two plain `constrain` statements always apply; the `mlsconstrain`
	 * only applies to MLS builds. */
	CU_ASSERT_EQUAL(nconstraints, mls ? 3u : 2u);

	for (uint32_t i = 0; i < nconstraints; i++) {
		const char **perms = NULL;
		uint32_t nperms = 0;
		CU_ASSERT_EQUAL_FATAL(
			sepol_constraint_get_perms(handle, constraints[i],
						   &perms, &nperms),
			0);
		CU_ASSERT_EQUAL(nperms, 1);
		if (nperms == 1)
			CU_ASSERT_STRING_EQUAL(perms[0], "PERM1");
		free(perms);

		const sepol_constraint_expr_t **exprs = NULL;
		uint32_t nexprs = 0;
		CU_ASSERT_EQUAL_FATAL(
			sepol_constraint_get_exprs(handle, constraints[i],
						   &exprs, &nexprs),
			0);

		if (nexprs == 1 &&
		    sepol_constraint_expr_get_type(exprs[0]) ==
			    SEPOL_CEXPR_TYPE_NAMES &&
		    sepol_constraint_expr_get_op(exprs[0]) ==
			    SEPOL_CEXPR_OP_EQ &&
		    sepol_constraint_expr_has_attr(exprs[0],
						   SEPOL_CEXPR_ATTR_TYPE)) {
			const char **names = NULL;
			uint32_t nnames = 0;
			CU_ASSERT_EQUAL_FATAL(
				sepol_constraint_expr_get_names(
					handle, exprs[0], &names, &nnames),
				0);
			if (nnames == 1 && names[0] &&
			    !strcmp(names[0], "TYPE1"))
				found_type_names_constraint = 1;
			free(names);
		}
		free(exprs);
	}

	CU_ASSERT_TRUE(found_type_names_constraint);
}

static void unseen(void)
{
	for (struct expected_class *e = expected_classes; e->name; e++) {
		e->seen = 0;
	}
}

static void seen(const sepol_class_t *item)
{
	const char *actual_name = sepol_class_get_name(item);
	const char *actual_common = sepol_class_get_common(item);
	uint32_t nactual_perms;
	const char **actual_perms;
	CU_ASSERT_EQUAL_FATAL(sepol_class_get_perms(handle, item, &actual_perms, &nactual_perms), 0);
	uint32_t nactual_constraints;
	const sepol_constraint_t **actual_constraints;
	CU_ASSERT_EQUAL_FATAL(sepol_class_get_constraints(handle, item, &actual_constraints, &nactual_constraints), 0);
	char actual_default_user = sepol_class_get_default_user(item);
	char actual_default_role = sepol_class_get_default_role(item);
	char actual_default_type = sepol_class_get_default_type(item);
	char actual_default_range = sepol_class_get_default_range(item);

	struct expected_class *e;
	for (e = expected_classes; e->name; e++) {
		if (strcmp(actual_name, e->name) == 0)
			break;
	}
	CU_ASSERT_PTR_NOT_NULL_FATAL(e->name);
	e->seen = 1;

	if (e->common) {
		CU_ASSERT_STRING_EQUAL(actual_common, e->common);
	} else {
		CU_ASSERT_PTR_NULL(actual_common);
	}

	CU_ASSERT_EQUAL(nactual_perms, e->nperms);
	qsort(actual_perms, nactual_perms, sizeof(char *), qstrcmp);
	for (size_t i = 0; i < nactual_perms && i < e->nperms; i++) {
		CU_ASSERT_STRING_EQUAL(actual_perms[i], e->perms[i]);
	}

	if (strcmp(e->name, "CLASS1") == 0)
		verify_class1_constraints(actual_constraints, nactual_constraints);
	else
		CU_ASSERT_EQUAL(nactual_constraints, 0);

	CU_ASSERT_EQUAL(actual_default_user, e->default_user);
	CU_ASSERT_EQUAL(actual_default_role, e->default_role);
	CU_ASSERT_EQUAL(actual_default_type, e->default_type);
	CU_ASSERT_EQUAL(actual_default_range, e->default_range);

	free(actual_perms);
	free(actual_constraints);
}

/*
 * constraint_expr_t.type_names->types is only populated on disk for
 * POLICY_KERN images with policyvers >= POLICYDB_VERSION_CONSTRAINT_NAMES
 * (see policydb_read() / get_name_list() in services.c); on older kernel
 * policy versions it is never read back and stays at the empty type_set_t
 * that constraint_expr_init() defaults it to. For those, the fully
 * expanded type membership of a "t1 == {...}" constraint instead lives in
 * the plain constraint_expr_t.names ebitmap that is always read.
 *
 * Build that exact on-disk shape by hand (a full compile + write + read
 * round trip through an old-version binary policy is unnecessarily heavy
 * for this) to make sure class_datum_to_record() falls back to .names
 * instead of silently reporting the constraint as having no names.
 */
void test_class_query_type_constraint_pre_v29_policy(void)
{
	sepol_policydb_t *p;
	CU_ASSERT_EQUAL_FATAL(sepol_policydb_create(&p), 0);
	p->p.policy_type = POLICY_KERN;
	p->p.policyvers = POLICYDB_VERSION_CONSTRAINT_NAMES - 1;

	/* One type, TYPE1, value 1 */
	type_datum_t *type = calloc(1, sizeof(*type));
	CU_ASSERT_PTR_NOT_NULL_FATAL(type);
	type->s.value = 1;
	type->primary = 1;
	type->flavor = TYPE_TYPE;
	char *tname = strdup("TYPE1");
	CU_ASSERT_PTR_NOT_NULL_FATAL(tname);
	CU_ASSERT_EQUAL_FATAL(
		hashtab_insert(p->p.p_types.table, tname, type), 0);
	p->p.p_types.nprim = 1;
	p->p.type_val_to_struct = calloc(1, sizeof(type_datum_t *));
	CU_ASSERT_PTR_NOT_NULL_FATAL(p->p.type_val_to_struct);
	p->p.type_val_to_struct[0] = type;
	p->p.sym_val_to_name[SYM_TYPES] = calloc(1, sizeof(char *));
	CU_ASSERT_PTR_NOT_NULL_FATAL(p->p.sym_val_to_name[SYM_TYPES]);
	p->p.sym_val_to_name[SYM_TYPES][0] = tname;

	/* One class, CLASS1, value 1, with a single "t1 == TYPE1" style
	 * constraint shaped like a pre-v29 on-disk kernel policy: .names
	 * has the bit, .type_names is left empty. */
	class_datum_t *cls = calloc(1, sizeof(*cls));
	CU_ASSERT_PTR_NOT_NULL_FATAL(cls);
	cls->s.value = 1;
	CU_ASSERT_EQUAL_FATAL(symtab_init(&cls->permissions, PERM_SYMTAB_SIZE), 0);

	constraint_expr_t *expr = calloc(1, sizeof(*expr));
	CU_ASSERT_PTR_NOT_NULL_FATAL(expr);
	CU_ASSERT_EQUAL_FATAL(constraint_expr_init(expr), 0);
	expr->expr_type = CEXPR_NAMES;
	expr->attr = CEXPR_TYPE;
	expr->op = CEXPR_EQ;
	CU_ASSERT_EQUAL_FATAL(ebitmap_set_bit(&expr->names, 0, 1), 0);
	/* expr->type_names intentionally left empty */

	constraint_node_t *con = calloc(1, sizeof(*con));
	CU_ASSERT_PTR_NOT_NULL_FATAL(con);
	con->expr = expr;
	cls->constraints = con;

	char *cname = strdup("CLASS1");
	CU_ASSERT_PTR_NOT_NULL_FATAL(cname);
	CU_ASSERT_EQUAL_FATAL(
		hashtab_insert(p->p.p_classes.table, cname, cls), 0);
	p->p.p_classes.nprim = 1;
	p->p.class_val_to_struct = calloc(1, sizeof(class_datum_t *));
	CU_ASSERT_PTR_NOT_NULL_FATAL(p->p.class_val_to_struct);
	p->p.class_val_to_struct[0] = cls;
	p->p.sym_val_to_name[SYM_CLASSES] = calloc(1, sizeof(char *));
	CU_ASSERT_PTR_NOT_NULL_FATAL(p->p.sym_val_to_name[SYM_CLASSES]);
	p->p.sym_val_to_name[SYM_CLASSES][0] = cname;

	sepol_class_t *record = NULL;
	CU_ASSERT_EQUAL_FATAL(
		sepol_class_query_by_value(handle, p, 1, &record), 0);
	CU_ASSERT_PTR_NOT_NULL_FATAL(record);

	const sepol_constraint_t **cons = NULL;
	uint32_t ncons = 0;
	CU_ASSERT_EQUAL_FATAL(
		sepol_class_get_constraints(handle, record, &cons, &ncons), 0);
	CU_ASSERT_EQUAL_FATAL(ncons, 1);

	const sepol_constraint_expr_t **exprs = NULL;
	uint32_t nexprs = 0;
	CU_ASSERT_EQUAL_FATAL(
		sepol_constraint_get_exprs(handle, cons[0], &exprs, &nexprs),
		0);
	CU_ASSERT_EQUAL_FATAL(nexprs, 1);

	const char **names = NULL;
	uint32_t nnames = 0;
	CU_ASSERT_EQUAL_FATAL(
		sepol_constraint_expr_get_names(handle, exprs[0], &names,
						&nnames),
		0);
	CU_ASSERT_EQUAL(nnames, 1);
	if (nnames == 1)
		CU_ASSERT_STRING_EQUAL(names[0], "TYPE1");

	free(names);
	free(exprs);
	free(cons);
	sepol_class_free(record);
	sepol_policydb_free(p);
}

void test_iter_classes_empty(void)
{
	sepol_class_iter_t *class_iter;
	CU_ASSERT_EQUAL_FATAL(sepol_class_iter_create(handle, empty_policy, &class_iter), 0);

	sepol_class_t *item;
	CU_ASSERT_EQUAL(sepol_class_iter_next(handle, class_iter, &item), 0);
	CU_ASSERT_PTR_NULL(item);
	CU_ASSERT_EQUAL(sepol_class_iter_next(handle, class_iter, &item), 0);
	CU_ASSERT_PTR_NULL(item);

	sepol_class_iter_destroy(class_iter);
}

void test_iter_classes_non_empty(void)
{
	unseen();
	sepol_class_t *item;
	sepol_class_iter_t *class_iter;
	CU_ASSERT_EQUAL_FATAL(sepol_class_iter_create(handle, iter_policy, &class_iter), 0);

	while (1) {
		CU_ASSERT_EQUAL(sepol_class_iter_next(handle, class_iter, &item), 0);
		if (!item)
			break;
		seen(item);
		sepol_class_free(item);
	}
	CU_ASSERT_EQUAL(sepol_class_iter_next(handle, class_iter, &item), 0);
	CU_ASSERT_PTR_NULL(item);

	for (struct expected_class *e = expected_classes; e->name; e++) {
		CU_ASSERT_TRUE(e->seen);
	}

	sepol_class_iter_destroy(class_iter);
}
