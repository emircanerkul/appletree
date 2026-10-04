//! Host identification: exactly the three facts a reader needs to place a
//! measurement — chip, RAM in GB, macOS version. Nothing else is collected,
//! and nothing leaves the machine.

use std::process::Command;

/// The machine a run happened on. Serialized with these three keys only.
pub struct Host {
    pub chip: String,
    pub ram_gb: u64,
    pub macos: String,
}

impl Host {
    pub fn detect() -> Host {
        Host {
            chip: sysctl("machdep.cpu.brand_string").unwrap_or_else(|| "unknown".into()),
            ram_gb: sysctl("hw.memsize")
                .and_then(|v| v.parse::<u64>().ok())
                .map(|bytes| bytes.div_ceil(1 << 30))
                .unwrap_or(0),
            macos: Command::new("sw_vers")
                .arg("-productVersion")
                .output()
                .ok()
                .filter(|o| o.status.success())
                .map(|o| String::from_utf8_lossy(&o.stdout).trim().to_string())
                .filter(|s| !s.is_empty())
                .unwrap_or_else(|| "unknown".into()),
        }
    }

    /// Filesystem-safe slug used in result directory names, e.g.
    /// `apple-m1-macos27.0`.
    pub fn slug(&self) -> String {
        let chip: String = self
            .chip
            .to_lowercase()
            .chars()
            .map(|c| if c.is_ascii_alphanumeric() { c } else { '-' })
            .collect();
        let chip = chip.trim_matches('-').to_string();
        let chip = chip.split('-').filter(|s| !s.is_empty()).collect::<Vec<_>>().join("-");
        format!("{}-macos{}", chip, self.macos)
    }

    pub fn json(&self) -> String {
        format!(
            "{{\"chip\":\"{}\",\"ram_gb\":{},\"macos\":\"{}\"}}",
            crate::jsonw::escape(&self.chip),
            self.ram_gb,
            crate::jsonw::escape(&self.macos)
        )
    }

    pub fn human(&self) -> String {
        format!("{} · {} GB RAM · macOS {}", self.chip, self.ram_gb, self.macos)
    }
}

fn sysctl(key: &str) -> Option<String> {
    let out = Command::new("sysctl").arg("-n").arg(key).output().ok()?;
    if !out.status.success() {
        return None;
    }
    let value = String::from_utf8_lossy(&out.stdout).trim().to_string();
    (!value.is_empty()).then_some(value)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn host_json_has_exactly_the_three_documented_keys() {
        let host = Host { chip: "Apple M1".into(), ram_gb: 16, macos: "27.0".into() };
        let json = host.json();
        assert_eq!(json, r#"{"chip":"Apple M1","ram_gb":16,"macos":"27.0"}"#);
        for key in ["chip", "ram_gb", "macos"] {
            assert!(json.contains(&format!("\"{key}\"")), "missing {key}");
        }
    }

    #[test]
    fn slug_is_filesystem_safe() {
        let host = Host { chip: "Apple M1 Pro".into(), ram_gb: 16, macos: "27.0".into() };
        assert_eq!(host.slug(), "apple-m1-pro-macos27.0");
        assert!(!host.slug().contains(' '));
    }
}
