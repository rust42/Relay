//! Manual end-to-end check of the proxy engine, independent of the Swift app.
//!
//!   cargo run --release --example smoke -- <data-dir> <port>
//!
//! Then point a client at it, e.g.
//!   curl -x http://127.0.0.1:8899 --cacert <data-dir>/charlesrs-ca.pem https://example.com
//!
//! Prints one line per captured request as they arrive.

use charles_core::model::{MockRule, ThrottleProfile};
use charles_core::CharlesController;

fn main() {
    let mut args = std::env::args().skip(1);
    let data_dir = args.next().unwrap_or_else(|| "/tmp/charlesrs-smoke".into());
    let port: u16 = args
        .next()
        .and_then(|p| p.parse().ok())
        .unwrap_or(8899);
    let mode = args.next();
    let with_mock = mode.as_deref() == Some("--mock");
    let with_throttle = mode.as_deref() == Some("--throttle");
    let with_loss = mode.as_deref() == Some("--loss");

    let controller = CharlesController::new(data_dir.clone());

    if with_throttle {
        controller.set_throttle_profile(ThrottleProfile {
            enabled: true,
            down_kbps: 100, // slow enough to be obviously measurable
            up_kbps: 100,
            latency_ms: 300,
            loss_probability: 0.0,
        });
        println!("throttle enabled: 100 kbps down, 300ms latency");
    }
    if with_loss {
        controller.set_throttle_profile(ThrottleProfile {
            enabled: true,
            down_kbps: 0,
            up_kbps: 0,
            latency_ms: 0,
            loss_probability: 1.0,
        });
        println!("throttle enabled: 100% simulated loss");
    }

    if with_mock {
        controller.set_mock_rules(vec![MockRule {
            id: "test-rule".into(),
            display_name: "Inject premium flag".into(),
            method: None,
            url_contains: "httpbin.org".into(),
            enabled: true,
            script: r#"
                function onResponse(req, res) {
                    var data = JSON.parse(res.body);
                    data.mocked = true;
                    data.injectedBy = "CharlesRS";
                    res.body = JSON.stringify(data);
                    res.headers["X-Mocked-By"] = "CharlesRS";
                    return res;
                }
            "#.into(),
            last_error: None,
        }]);
        println!("mock rule registered for httpbin.org/json");
    }

    controller.start(port).expect("proxy failed to start");
    println!("proxy listening on 127.0.0.1:{port}");
    println!("ca cert: {data_dir}/charlesrs-ca.pem");
    println!("state: {:?}", controller.state());

    let mut seen = 0usize;
    loop {
        std::thread::sleep(std::time::Duration::from_millis(200));
        let all = controller.recent_requests(1000);
        if all.len() > seen {
            // recent_requests is newest-first; walk the new ones oldest-first.
            for req in all[..all.len() - seen].iter().rev() {
                println!(
                    "CAPTURED [{}/{:?}] {} {} -> {:?} ({} bytes in, {} bytes out, {:?} ms, body_b64_len={:?}, intercepted_by={:?})",
                    req.process_name.as_deref().unwrap_or("?"),
                    req.process_id,
                    req.method,
                    req.url,
                    req.status_code,
                    req.bytes_received,
                    req.bytes_sent,
                    req.duration_ms,
                    req.response_body_base64.as_ref().map(|s| s.len()),
                    req.intercepted_by,
                );
                for rule in controller.mock_rules() {
                    if let Some(err) = rule.last_error {
                        println!("MOCK RULE ERROR [{}]: {err}", rule.display_name);
                    }
                }
            }
            seen = all.len();
        }
    }
}
