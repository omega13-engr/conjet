use crate::arch::aarch64;
use crate::devices::bus::{MmioDevice, MmioError};

#[derive(Debug, Clone)]
pub struct Pl011Uart {
    base: u64,
    size: u64,
    bytes: Vec<u8>,
    max_buffered_bytes: usize,
}

impl Default for Pl011Uart {
    fn default() -> Self {
        Self::new(aarch64::UART_BASE, aarch64::UART_SIZE)
    }
}

impl Pl011Uart {
    pub const DATA_REGISTER: u64 = 0x00;
    pub const FLAG_REGISTER: u64 = 0x18;
    pub const RECEIVE_FIFO_EMPTY: u32 = 1 << 4;
    pub const TRANSMIT_FIFO_FULL: u32 = 1 << 5;
    pub const TRANSMIT_FIFO_EMPTY: u32 = 1 << 7;

    pub fn new(base: u64, size: u64) -> Self {
        Self {
            base,
            size,
            bytes: Vec::new(),
            max_buffered_bytes: 64 * 1024,
        }
    }

    pub fn drain_string(&mut self) -> String {
        let bytes = std::mem::take(&mut self.bytes);
        String::from_utf8_lossy(&bytes).into_owned()
    }

    pub fn snapshot_string(&self) -> String {
        String::from_utf8_lossy(&self.bytes).into_owned()
    }

    fn push_byte(&mut self, byte: u8) {
        self.bytes.push(byte);
        if self.bytes.len() > self.max_buffered_bytes {
            let drop_count = self.bytes.len() - self.max_buffered_bytes;
            self.bytes.drain(0..drop_count);
        }
    }
}

impl MmioDevice for Pl011Uart {
    fn as_any_mut(&mut self) -> &mut dyn std::any::Any {
        self
    }

    fn base(&self) -> u64 {
        self.base
    }

    fn size(&self) -> u64 {
        self.size
    }

    fn read(&mut self, offset: u64, _size: u8) -> Result<u64, MmioError> {
        let value = match offset {
            Self::FLAG_REGISTER => Self::RECEIVE_FIFO_EMPTY | Self::TRANSMIT_FIFO_EMPTY,
            0xfe0 => 0x11,
            0xfe4 => 0x10,
            0xfe8 => 0x04,
            0xfec => 0x00,
            0xff0 => 0x0d,
            0xff4 => 0xf0,
            0xff8 => 0x05,
            0xffc => 0xb1,
            _ => 0,
        };
        Ok(u64::from(value))
    }

    fn write(&mut self, offset: u64, value: u64, _size: u8) -> Result<(), MmioError> {
        if offset == Self::DATA_REGISTER {
            self.push_byte(value as u8);
        }
        Ok(())
    }
}
