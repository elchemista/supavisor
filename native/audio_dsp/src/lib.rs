use rustfft::{num_complex::Complex, FftPlanner};
use rustler::{Binary, Env, OwnedBinary};
use std::f64::consts::PI;

/// Whisper large-v3 frontend: 16kHz, 30s, FFT400/hop160, 128 Slaney mel bands.
/// This bounded dirty-scheduler NIF only computes features; ONNX handles inference.
#[rustler::nif(schedule = "DirtyCpu")]
fn whisper_mel<'a>(env: Env<'a>, pcm: Binary<'a>) -> Result<Binary<'a>, String> {
    if pcm.is_empty() || pcm.len() % 4 != 0 || pcm.len() > 480_000 * 4 {
        return Err("Audio must contain at most 30 seconds of mono float32 PCM".into());
    }
    let mut audio = vec![0.0f64; 480_000];
    for (i, b) in pcm.as_slice().chunks_exact(4).enumerate() {
        let value = f32::from_le_bytes(b.try_into().unwrap());
        if !value.is_finite() {
            return Err("Audio contains invalid samples".into());
        }
        audio[i] = value as f64;
    }
    let max_mel = 15.0 + (8.0f64).ln() * 27.0 / (6.4f64).ln();
    let frequencies: Vec<f64> = (0..130)
        .map(|i| {
            let mel = i as f64 * max_mel / 129.0;
            if mel >= 15.0 {
                1000.0 * ((mel - 15.0) * (6.4f64).ln() / 27.0).exp()
            } else {
                mel * 200.0 / 3.0
            }
        })
        .collect();
    let filters: Vec<Vec<(usize, f64)>> = (0..128)
        .map(|i| {
            (0..201)
                .filter_map(|k| {
                    let hz = k as f64 * 40.0;
                    let lo = (hz - frequencies[i]) / (frequencies[i + 1] - frequencies[i]);
                    let hi = (frequencies[i + 2] - hz) / (frequencies[i + 2] - frequencies[i + 1]);
                    let weight = lo.min(hi).max(0.0) * 2.0 / (frequencies[i + 2] - frequencies[i]);
                    if weight > 0.0 {
                        Some((k, weight))
                    } else {
                        None
                    }
                })
                .collect()
        })
        .collect();
    let window: Vec<f64> = (0..400)
        .map(|i| 0.5 - 0.5 * (2.0 * PI * i as f64 / 400.0).cos())
        .collect();
    let fft = FftPlanner::<f64>::new().plan_fft_forward(400);
    let mut buffer = vec![Complex::new(0.0, 0.0); 400];
    let mut scratch = vec![Complex::new(0.0, 0.0); fft.get_inplace_scratch_len()];
    let mut features = vec![0.0f64; 128 * 3000];
    let mut maximum = f64::NEG_INFINITY;
    for frame in 0..3000 {
        for i in 0..400 {
            let index = frame as i64 * 160 + i as i64 - 200;
            let reflected = if index < 0 {
                -index
            } else if index >= 480_000 {
                959_998 - index
            } else {
                index
            };
            buffer[i] = Complex::new(audio[reflected as usize] * window[i], 0.0);
        }
        fft.process_with_scratch(&mut buffer, &mut scratch);
        let power: Vec<f64> = buffer[..201].iter().map(|v| v.norm_sqr()).collect();
        for (band, filter) in filters.iter().enumerate() {
            let value = filter
                .iter()
                .map(|(k, w)| power[*k] * w)
                .sum::<f64>()
                .max(1e-10)
                .log10();
            maximum = maximum.max(value);
            features[band * 3000 + frame] = value;
        }
    }
    let mut binary =
        OwnedBinary::new(features.len() * 4).ok_or("Cannot allocate audio features")?;
    for (dst, value) in binary.as_mut_slice().chunks_exact_mut(4).zip(features) {
        dst.copy_from_slice(&(((value.max(maximum - 8.0) + 4.0) / 4.0) as f32).to_le_bytes());
    }
    Ok(binary.release(env))
}
rustler::init!("Elixir.Supavisor.Services.LocalModels.AudioDSP");
