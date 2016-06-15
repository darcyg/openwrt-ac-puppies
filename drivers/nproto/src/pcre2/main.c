#ifdef HAVE_CONFIG_H
#include "config.h"
#endif

#include <linux/kernel.h>
#include <linux/module.h>
#include <linux/slab.h>
#include "pcre2_internal.h"
#include "pcre2.h"

#define MACHINE_STACK_SIZE 32768
#define TEMP_MAX 1000

#define COPIED_PATTERN_SIZE 1024
#define NAMED_GROUP_LIST_SIZE  20
#define COMPILE_WORK_SIZE (2048*LINK_SIZE)	/* Size in code units */
#define C32_WORK_SIZE \
  ((COMPILE_WORK_SIZE * sizeof(PCRE2_UCHAR))/sizeof(uint32_t))

// sizeof(unsigned char)*MACHINE_STACK_SIZE
struct kmem_cache *local_space_cache = NULL;
// sizeof(PCRE2_SIZE)*TEMP_MAX
struct kmem_cache *local_offsets_cache = NULL;
// sizeof(int)*TEMP_MAX
struct kmem_cache *local_workspace_cache = NULL;

// sizeof(unsigned char)*COPIED_PATTERN_SIZE
struct kmem_cache *stack_copied_pattern_cache = NULL;
// sizeof(named_group)*NAMED_GROUP_LIST_SIZE
struct kmem_cache *named_groups_cache = NULL;
// sizeof(uint32_t)*C32_WORK_SIZE
struct kmem_cache *c32workspace_cache = NULL;

int pcre2_init(void)
{
	pr_debug("libpcre2 init\n");

	local_space_cache = kmem_cache_create("local_space",
					      MACHINE_STACK_SIZE, 0, 0, NULL);
	if (local_space_cache == NULL)
		goto out_of_memory;

	local_offsets_cache = kmem_cache_create("local_offsets",
						sizeof(PCRE2_SIZE) * TEMP_MAX, 0, 0, NULL);
	if (local_offsets_cache == NULL)
		goto out_of_memory;

	local_workspace_cache = kmem_cache_create("local_workspace",
						  sizeof(int) * TEMP_MAX, 0, 0, NULL);
	if (local_workspace_cache == NULL)
		goto out_of_memory;

	stack_copied_pattern_cache = kmem_cache_create("stack_copied_pattern",
						       COPIED_PATTERN_SIZE, 0, 0, NULL);
	if (stack_copied_pattern_cache == NULL)
		goto out_of_memory;

	named_groups_cache = kmem_cache_create("named_groups",
					       sizeof(named_group) *
					       NAMED_GROUP_LIST_SIZE, 0, 0, NULL);
	if (named_groups_cache == NULL)
		goto out_of_memory;

	c32workspace_cache = kmem_cache_create("c32workspace",
					       sizeof(uint32_t) * C32_WORK_SIZE, 0, 0, NULL);
	if (c32workspace_cache == NULL)
		goto out_of_memory;

	return 0;

 out_of_memory:

	if (local_space_cache)
		kmem_cache_destroy(local_space_cache);

	if (local_offsets_cache)
		kmem_cache_destroy(local_offsets_cache);

	if (local_workspace_cache)
		kmem_cache_destroy(local_workspace_cache);

	if (stack_copied_pattern_cache)
		kmem_cache_destroy(stack_copied_pattern_cache);

	if (named_groups_cache)
		kmem_cache_destroy(named_groups_cache);

	if (c32workspace_cache)
		kmem_cache_destroy(c32workspace_cache);

	return -ENOMEM;

}

void pcre2_exit(void)
{
	pr_debug("libpcre2 exit\n");

	if (local_space_cache)
		kmem_cache_destroy(local_space_cache);

	if (local_offsets_cache)
		kmem_cache_destroy(local_offsets_cache);

	if (local_workspace_cache)
		kmem_cache_destroy(local_workspace_cache);

	if (stack_copied_pattern_cache)
		kmem_cache_destroy(stack_copied_pattern_cache);

	if (named_groups_cache)
		kmem_cache_destroy(named_groups_cache);

	if (c32workspace_cache)
		kmem_cache_destroy(c32workspace_cache);

}
