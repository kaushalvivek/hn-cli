use clap::Parser;
use hn_cli::cli::Cli;

#[tokio::main]
async fn main() {
    let cli = Cli::parse();
    let json = cli.json;
    if let Err(error) = cli.run().await {
        if json {
            eprintln!(
                "{}",
                serde_json::to_string_pretty(&error.payload()).unwrap_or_else(|_| "{}".into())
            );
        } else {
            eprintln!("error: {error}");
        }
        std::process::exit(1);
    }
}
