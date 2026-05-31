pub fn render(value: f64) -> String {
    let scaled = (value * 1000.0).round() as i64;
    let whole = scaled / 1000;
    let fraction = (scaled.abs() % 1000) as u64;
    format!("{whole}.{fraction:03}")
}