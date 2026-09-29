A stage that sets up A/B upgrades using a 4 partition model:

1. boot partition
2. root partition A
3. root partition B
4. data partition

The actual partitions are created by the `export-image` stage. This stage sets up what is necessary to make it work at
runtime.
