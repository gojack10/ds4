---
name: dsv4-sifttext-context
description: Mandatory opening context retrieval for any work in the dsv4 repository. At the start of the first task in a session whose cwd is this repo, load the M5 Max SiftText outline plus the port 8002 and com.dsv4.server nodes before investigating or changing code.
---

# DSV4 SiftText Context

Run this once before the first repository task in each session. Do not repeat it on later turns unless the user asks or the nodes changed.

1. Use `ideation_sql` to find the root node named `M5 Max` and obtain its `tree_id`:

   ```sql
   SELECT id, tree_id, name, status
   FROM nodes
   WHERE parent_id IS NULL AND name = 'M5 Max';
   ```

2. Call `ideation_get_outline` with that `tree_id` and `max_depth: 4`.
3. From the outline, locate `port 8002` and `com.dsv4.server`, then call `ideation_get_node` for both.
4. Before acting, apply their current scope, crystallization, and warnings—especially proxy routing, idle lifecycle, memory limits, cancellation, and cache durability constraints.

This retrieval is read-only. Do not mutate SiftText unless the user explicitly asks. If the ideation tools are unavailable, say the opening context could not be loaded instead of guessing.
