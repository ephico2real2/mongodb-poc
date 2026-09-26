# Enhancements

Changes to the lab's cluster and to the operators it runs, each with its backup, its
test, and what was measured.

| | |
|---|---|
| [`storage-volume-expansion.md`](storage-volume-expansion.md) | `allowVolumeExpansion` on `crc-csi-hostpath-provisioner`: what it enables, what it cannot do on CRC's hostpath storage, and what the MongoDB operator does with resizes and retained volumes |
| [`storageclass-crc-csi-hostpath-provisioner.yaml`](storageclass-crc-csi-hostpath-provisioner.yaml) | the StorageClass as applied |
| [`backup/`](backup/) | the StorageClass before the change — as found, and ready to restore |
| [`test/expansion-test.yaml`](test/expansion-test.yaml) | the claim and pod used to measure a resize |
