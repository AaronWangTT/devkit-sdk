# AZ3166 Core 3.1.3

Core 3.1.3 fixes signed OTA activation persistence on the AZ3166 MiCO
parameter-storage implementation.

## Release highlights

- Persist the complete boot table through `mico_system_context_update()` rather
  than the section API, whose strict bounds check rejects a full boot-table
  write.
- Read the in-memory boot table through the MiCO context and independently
  verify both persisted parameter partitions.
- Treat matching persisted primary and backup tables as authoritative even
  when the write API reports an error after data persistence.
- Use the bootloader-compatible uppercase `U` upgrade marker.
- Raise the per-operation activation bound from 5 to 15 seconds based on
  physical AZ3166 measurements.
- Add host regression coverage for persistence that succeeds despite a write
  status error.

The signed package format and staging APIs are unchanged from Core 3.1.2.
