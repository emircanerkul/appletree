//! Shared attribute-list FFI glue: the `attrlist_t` layout and the
//! little-endian readers the bulk parsers use to walk attribute records.

#[repr(C)]
pub(crate) struct AttrList {
    pub(crate) bitmapcount: u16,
    pub(crate) reserved: u16,
    pub(crate) commonattr: u32,
    pub(crate) volattr: u32,
    pub(crate) dirattr: u32,
    pub(crate) fileattr: u32,
    pub(crate) forkattr: u32,
}

pub(crate) fn u32_at(b: &[u8], off: usize) -> u32 {
    u32::from_le_bytes(b[off..off + 4].try_into().unwrap())
}

pub(crate) fn i64_at(b: &[u8], off: usize) -> i64 {
    i64::from_le_bytes(b[off..off + 8].try_into().unwrap())
}

pub(crate) fn u64_at(b: &[u8], off: usize) -> u64 {
    u64::from_le_bytes(b[off..off + 8].try_into().unwrap())
}
