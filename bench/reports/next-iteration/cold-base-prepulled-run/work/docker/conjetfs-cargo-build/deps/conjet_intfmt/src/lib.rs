pub fn render(value: u64) -> String {
    let mut n = value;
    let mut digits = [0u8; 20];
    let mut index = digits.len();
    if n == 0 {
        index -= 1;
        digits[index] = b'0';
    }
    while n > 0 {
        index -= 1;
        digits[index] = b'0' + (n % 10) as u8;
        n /= 10;
    }
    String::from_utf8(digits[index..].to_vec()).expect("ascii digits")
}