# Netbox Usage Scenarios

## Scenario 1: Automated Unifi Device Sync

**Actor**: unifi2netbox CronJob  
**Trigger**: Scheduled execution (every 6 hours)  
**Precondition**: NetBox is running, Unifi controllers are reachable via Tailscale/LAN

### Flow

1. CronJob triggers unifi2netbox container
2. Script authenticates to Ottawa Unifi controller (`https://192.168.169.1`) using stored credentials + OTP seed
3. Script queries Unifi API for all adopted devices at the Ottawa site
4. For each device:
   a. Checks if device exists in NetBox (by MAC address or serial number)
   b. If new: creates device with manufacturer (Ubiquiti), device type, name, serial, and assigns to "Ottawa" site
   c. If existing: updates any changed fields (IP, firmware version, status)
   d. Syncs device interfaces and IP assignments
5. Repeats steps 2-4 for Robbinsdale controller (`https://192.168.50.1`)
6. Logs summary: X devices created, Y updated, Z errors
7. CronJob completes with exit code 0 (success) or 1 (partial failure)

### Expected Outcome

- All Unifi-adopted devices appear in NetBox under the correct site
- Device types match Ubiquiti product catalog
- IP addresses are assigned to the correct interfaces
- Subsequent runs are idempotent (no duplicates created)

### Error Scenarios

| Error | Expected Behavior |
|-------|-------------------|
| Unifi controller unreachable | Log error, skip that controller, continue with next |
| Duplicate device detected | Log warning, update existing device instead of creating |
| Invalid device type | Log error, create device with generic type, flag for review |
| NetBox API unreachable | Log critical error, exit with code 1 |

---

## Scenario 2: IP Allocation Workflow

**Actor**: Network administrator (Raj)  
**Trigger**: Need to assign IP for a new service  
**Precondition**: Prefixes for the target site exist in NetBox

### Flow

1. Admin navigates to NetBox UI → IPAM → Prefixes
2. Selects the target prefix (e.g., `192.168.169.0/24` for Ottawa LAN)
3. Views available IPs within the prefix (NetBox shows which are free vs. assigned)
4. Clicks "Add an IP Address" or uses the "first available" function
5. Fills in:
   - IP Address: auto-assigned or manually selected
   - Status: Active
   - DNS Name: (optional)
   - Description: Purpose of the allocation
   - Assigned Interface: (optional, link to a device interface)
   - Tenant: (optional)
6. Saves the IP address assignment
7. (Optional) Uses the API to programmatically allocate IPs for Kubernetes services

### Expected Outcome

- IP is marked as assigned in NetBox
- Prefix utilization percentage updates automatically
- IP appears in the global IP address list and can be found via search
- No duplicate IP can be assigned within the same VRF/prefix

### Alternative Flow: Bulk Import

1. Admin navigates to IPAM → IP Addresses → Import
2. Uploads CSV with IP addresses, status, and descriptions
3. NetBox validates all entries and reports conflicts
4. Admin confirms import
5. All IPs created in bulk

---

## Scenario 3: Viewing Network Inventory Across Sites

**Actor**: Network administrator  
**Trigger**: Need to audit or plan network changes  
**Precondition**: Unifi sync has populated device inventory

### Flow

1. Admin navigates to NetBox UI → Devices → Devices
2. Views unified inventory showing all devices across Ottawa and Robbinsdale
3. Filters by site to see only Ottawa devices (or Robbinsdale)
4. Clicks on a specific device (e.g., "USW-Pro-24-PoE") to see:
   - Device details (model, serial, firmware, status)
   - Interfaces and their configurations
   - IP addresses assigned to interfaces
   - Cable connections (if documented)
   - Location in rack (if assigned)
5. Uses the search to find a device by name, IP, or MAC address
6. Exports inventory to CSV for reporting

### Expected Outcome

- Unified view of all network devices regardless of which Unifi controller manages them
- Device details are accurate and match what the Unifi controller reports
- Search works across all fields (name, IP, MAC, serial)
- Can filter by site, role, manufacturer, status

---

## Scenario 4: Rack Layout Documentation

**Actor**: Network administrator  
**Trigger**: Planning physical changes or documenting current layout  
**Precondition**: Sites and racks exist in NetBox

### Flow

1. Admin navigates to NetBox UI → DCIM → Racks
2. Selects a rack at the Ottawa site
3. Views the rack elevation diagram showing:
   - Which devices are installed in which rack units
   - Empty rack units available for new equipment
   - Power utilization (if power feeds are configured)
4. To add a device to the rack:
   a. Navigates to the device
   b. Edits the device to set Rack and Position (U number)
   c. Sets Face (front/rear)
   d. Saves
5. Rack elevation diagram updates to show the new device placement
6. Can view both front and rear views of the rack

### Expected Outcome

- Visual rack elevation shows physical layout
- Can plan new device placement by identifying empty units
- Device height (in U) is automatically determined from device type

---

## Scenario 5: Adding a New VLAN

**Actor**: Network administrator  
**Trigger**: Need to create a new VLAN for network segmentation  
**Precondition**: VLAN groups and sites exist in NetBox

### Flow

1. Admin navigates to NetBox UI → IPAM → VLANs
2. Clicks "Add VLAN"
3. Fills in:
   - Site: Ottawa (or Robbinsdale)
   - VLAN Group: (site VLAN group)
   - VLAN ID: (e.g., 100)
   - Name: (e.g., "IoT")
   - Status: Active
   - Role: (optional)
   - Description: Purpose of the VLAN
4. Saves the VLAN
5. Creates an associated prefix under IPAM → Prefixes
   - Links the prefix to the new VLAN
   - Defines the subnet (e.g., `192.168.100.0/24`)
6. VLAN now appears in the VLAN list and is linked to its prefix

### Expected Outcome

- VLAN is documented with its associated subnet
- NetBox prevents duplicate VLAN IDs within the same VLAN group
- Prefix utilization can be tracked as IPs are allocated within the VLAN's subnet

---

## Scenario 6: Programmatic Access via API

**Actor**: Automation script / CI pipeline  
**Trigger**: Infrastructure-as-code needs network data  
**Precondition**: API token exists with appropriate permissions

### Flow

1. Script authenticates to NetBox API with token: `Authorization: Token <api_token>`
2. Queries available prefixes: `GET /api/ipam/prefixes/?site=ottawa&status=active`
3. Requests next available IP: `POST /api/ipam/prefixes/{id}/available-ips/`
4. Creates a device record: `POST /api/dcim/devices/` with device type, site, role
5. Assigns IP to device interface: `POST /api/ipam/ip-addresses/` with interface assignment

### Expected Outcome

- Full CRUD operations available via REST API
- GraphQL queries available for complex data retrieval
- API responses include nested related objects for efficient data access
- Rate limiting prevents API abuse
