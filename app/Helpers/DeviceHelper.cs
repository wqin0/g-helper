using System.Runtime.InteropServices;

namespace GHelper.Helpers
{
    public static class DeviceHelper
    {
        const string GUID_DEVCLASS_DISPLAY = "{4D36E968-E325-11CE-BFC1-08002BE10318}";
        const uint CM_GETIDLIST_FILTER_CLASS = 0x00000200;
        const uint CM_GETIDLIST_FILTER_PRESENT = 0x00000100;
        const uint DN_HAS_PROBLEM = 0x00000400;
        const uint CM_DRP_DEVICEDESC = 0x00000001;
        const uint CM_DRP_CONFIGFLAGS = 0x0000000B;
        const uint CONFIGFLAG_DISABLED = 0x00000001;
        const uint CM_PROB_DISABLED = 22;

        [DllImport("CfgMgr32.dll", CharSet = CharSet.Unicode)]
        static extern int CM_Get_Device_ID_List_SizeW(out uint pulLen, string pszFilter, uint ulFlags);

        [DllImport("CfgMgr32.dll", CharSet = CharSet.Unicode)]
        static extern int CM_Get_Device_ID_ListW(string pszFilter, char[] Buffer, uint BufferLen, uint ulFlags);

        [DllImport("CfgMgr32.dll", CharSet = CharSet.Unicode)]
        static extern int CM_Locate_DevNodeW(out uint pdnDevInst, string pDeviceID, uint ulFlags);

        [DllImport("CfgMgr32.dll")]
        static extern int CM_Get_DevNode_Status(out uint pulStatus, out uint pulProblemNumber, uint dnDevInst, uint ulFlags);

        [DllImport("CfgMgr32.dll", CharSet = CharSet.Unicode)]
        static extern int CM_Get_DevNode_Registry_PropertyW(uint dnDevInst, uint ulProperty, out uint pulRegDataType, char[] Buffer, ref uint pulLength, uint ulFlags);

        [DllImport("CfgMgr32.dll", CharSet = CharSet.Unicode)]
        static extern int CM_Get_DevNode_Registry_PropertyW(uint dnDevInst, uint ulProperty, out uint pulRegDataType, out uint Buffer, ref uint pulLength, uint ulFlags);

        static string ProblemText(uint problem) => problem switch
        {
            1 => "Device is not configured",
            10 => "Device cannot start",
            12 => "Not enough free resources",
            14 => "Restart required",
            18 => "Drivers need to be reinstalled",
            21 => "Device is being removed",
            22 => "Device is disabled",
            28 => "Drivers are not installed",
            31 or 39 => "Driver failed to load",
            32 => "Driver service is disabled",
            37 => "Driver initialization failed",
            38 => "Previous driver still loaded, restart required",
            43 => "Device stopped because it reported problems",
            44 => "Device stopped by an application or service",
            48 => "Driver is blocked from loading",
            52 => "Driver signature cannot be verified",
            54 => "Device is being reset",
            _ => "Unknown problem",
        };

        // Present display adapters, including disabled ones
        static string[] GetDisplayDeviceIds()
        {
            uint flags = CM_GETIDLIST_FILTER_CLASS | CM_GETIDLIST_FILTER_PRESENT;
            if (CM_Get_Device_ID_List_SizeW(out uint len, GUID_DEVCLASS_DISPLAY, flags) != 0 || len <= 1) return [];

            var buffer = new char[len];
            if (CM_Get_Device_ID_ListW(GUID_DEVCLASS_DISPLAY, buffer, len, flags) != 0) return [];

            return new string(buffer).Split('\0', StringSplitOptions.RemoveEmptyEntries);
        }

        static bool IsVendor(string id, string vendor) => id.StartsWith("PCI\\VEN_" + vendor, StringComparison.OrdinalIgnoreCase);

        public static string? GetGpuError()
        {
            string? error = null;
            string? iGpu = AppConfig.IsDisableIGpuUltimate() ? GetIGpuId() : null;

            foreach (var id in GetDisplayDeviceIds())
                if ((IsVendor(id, "10DE") || IsVendor(id, "1002")) &&
                    CM_Locate_DevNodeW(out uint devInst, id, 0) == 0 &&
                    CM_Get_DevNode_Status(out uint status, out uint problem, devInst, 0) == 0 &&
                    (status & DN_HAS_PROBLEM) != 0 &&
                    !(problem == CM_PROB_DISABLED && id == iGpu)) // iGPU disabled on purpose in Ultimate mode
                {
                    var name = new char[256];
                    uint size = 512;
                    string device = CM_Get_DevNode_Registry_PropertyW(devInst, CM_DRP_DEVICEDESC, out _, name, ref size, 0) == 0
                        ? new string(name, 0, (int)size / 2).TrimEnd('\0') : id;
                    error = $"{device}\nError {problem}: {ProblemText(problem)}";
                }

            return error;
        }

        // iGPU is the only Intel display adapter, or the only AMD one when the dGPU is NVIDIA.
        // All-AMD laptops can't be told apart by vendor ID, so return null rather than risk picking the dGPU.
        public static string? GetIGpuId()
        {
            var ids = GetDisplayDeviceIds();

            var intel = ids.Where(id => IsVendor(id, "8086")).ToArray();
            if (intel.Length > 0) return intel.Length == 1 ? intel[0] : null;

            if (!Program.acpi.IsNVidiaGPU() && !ids.Any(id => IsVendor(id, "10DE"))) return null;

            var amd = ids.Where(id => IsVendor(id, "1002")).ToArray();
            return amd.Length == 1 ? amd[0] : null;
        }

        // Disabled now, or flagged to stay disabled after reboot. Null if device not found
        public static bool? IsDeviceDisabled(string id)
        {
            if (CM_Locate_DevNodeW(out uint devInst, id, 0) != 0) return null;

            if (CM_Get_DevNode_Status(out uint status, out uint problem, devInst, 0) == 0 &&
                (status & DN_HAS_PROBLEM) != 0 && problem == CM_PROB_DISABLED) return true;

            uint size = sizeof(uint);
            return CM_Get_DevNode_Registry_PropertyW(devInst, CM_DRP_CONFIGFLAGS, out _, out uint configFlags, ref size, 0) == 0 &&
                (configFlags & CONFIGFLAG_DISABLED) != 0;
        }

        // Returns true if device ends up in the requested state
        public static bool SetDeviceEnabled(string id, bool enabled)
        {
            if (IsDeviceDisabled(id) == !enabled) return true;

            if (!ProcessHelper.IsUserAdministrator())
            {
                Logger.WriteLine($"Admin rights required to {(enabled ? "enable" : "disable")} {id}");
                return false;
            }

            ProcessHelper.RunCMD(Path.Combine(Environment.SystemDirectory, "pnputil.exe"), $"/{(enabled ? "enable" : "disable")}-device \"{id}\"", timeoutMs: 30000);
            return IsDeviceDisabled(id) == !enabled;
        }
    }
}
