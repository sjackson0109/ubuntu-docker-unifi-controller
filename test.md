## Implementation Steps

**Pre-change preparation (before change window)**  
1. Validate that **AponeoKeyProvider** is listed and healthy via `dcli com vmware vcenter cryptomanager kms providers list`  
2. Confirm ESXi hosts trust Aponeo (certificate, connectivity)  
3. Ensure a full backup of the target VM exists (including NVram, config, disks)  
4. Document the VM’s existing firmware mode, settings, and dependencies  
5. Plan rollback steps and communicate change window  

**During change window**  
1. Place cluster in maintenance mode: disable vSphere HA and DRS migrations  
2. Confirm Aponeo key provider is operational and accessible  
3. Export and download key provider backup (if not already done):  
   - Use `dcli com vmware vcenter cryptomanager kms providers export --provider AponeoKeyProvider`  
   - Capture `url` and `download_token`  
   - Use `curl` or HTTP POST to download the `.p12` backup using the token and `url`  
4. (Optional) Set Aponeo as default key provider for cluster, if required  
5. Power off the target VM gracefully  
6. If necessary, convert the VM’s firmware from BIOS to UEFI  
7. Enable VM encryption using **AponeoKeyProvider**  
8. Add a vTPM device to the VM’s hardware configuration  
9. Power on the VM and observe boot behavior  
10. Inside guest OS, verify the TPM is present and functioning (using OS TPM tools)  
11. Perform a backup & restore test (preserving vTPM / NVram state)  
12. Re-enable vSphere HA and DRS migrations  
13. Validate HA behavior, restart policies, and failover functionality  
14. Monitor VM, host, vCenter, and KMS logs for errors over a defined period (e.g. 24 hours)  
15. Document the outcome, timings, anomalies, and lessons learned  

**Rollback plan (if any step fails)**  
- Revert VM configuration: remove vTPM, disable encryption, revert firmware  
- Restore VM from original backup (including NVram and config)  
- Restore cluster HA and DRS settings  
- Revert any default key provider changes  
- Log all steps and notify stakeholders  
