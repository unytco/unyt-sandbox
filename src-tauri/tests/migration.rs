use hdi::prelude::*;
use holochain_client::ExternIO;
use std::str::FromStr;
use tauri_app_lib::{happ_bundle, migration::migrate_app};
use tauri_plugin_holochain::{
    vec_to_locked, AppBundle, HolochainRuntime, HolochainRuntimeConfig, NetworkConfig,
};
use tempdir::TempDir;

pub fn old_happ_bundle() -> AppBundle {
    let bytes = include_bytes!("../../workdir/domino.happ");
    AppBundle::decode(bytes).expect("Failed to decode domino happ")
}

#[tokio::test(flavor = "multi_thread")]
async fn migrate_app_test() {
    let tmp = TempDir::new("domino").unwrap();

    let runtime = HolochainRuntime::launch(
        vec_to_locked(vec![]),
        HolochainRuntimeConfig {
            holochain_dir: tmp.path().to_path_buf(),
            network_config: NetworkConfig::default(),
            admin_port: None,
        },
    )
    .await
    .unwrap();

    let old_app_id = String::from("app1");
    let new_app_id = String::from("app2");

    println!("Installing old app");
    runtime
        .install_app(old_app_id.clone(), old_happ_bundle(), None, None, None)
        .await
        .unwrap();

    println!("Getting old app websocket");
    let app_ws = runtime
        .app_websocket(old_app_id.clone(), holochain_client::AllowedOrigins::Any)
        .await
        .unwrap();

    #[derive(Debug, Serialize, Deserialize, SerializedBytes, Clone)]
    pub struct AgentDetails {
        pub pub_key: AgentPubKeyB64,
        pub name: String,
        pub thumbnail: String,
        pub notes: String,
    }
    println!("Adding agent details");
    app_ws
        .call_zome(
            holochain_client::ZomeCallTarget::RoleName("agent_details".into()),
            "agent_details".into(),
            "add_agent_details".into(),
            ExternIO::encode(AgentDetails {
                pub_key: AgentPubKeyB64::from_str(
                    "uhCAkEwV2CAma4Pi8Pk8ym3yML0gEyJmeqVhNkEB_C2m5HvBPpiHL",
                )
                .unwrap(),
                name: "alice".into(),
                thumbnail: "alice".into(),
                notes: "alice".into(),
            })
            .unwrap(),
        )
        .await
        .unwrap();
    println!("Migrating");
    migrate_app(
        &runtime,
        old_app_id,
        new_app_id.clone(),
        happ_bundle(),
        None,
        Some("network_seed".into()),
    )
    .await
    .unwrap();
    println!("Migrated");
    let admin_ws = runtime.admin_websocket().await.unwrap();
    let apps = admin_ws.list_apps(None).await.unwrap();
    println!("apps: {:?}", apps);
    let app_info = apps.iter().find(|app| app.installed_app_id == new_app_id);
    println!("app_info: {:?}", app_info);
    assert!(app_info.is_some());
    // let app_ws = runtime
    //     .app_websocket(
    //         app_info.installed_app_id.clone(),
    //         holochain_client::AllowedOrigins::Any,
    //     )
    //     .await
    //     .unwrap();

    // let app_ws = runtime
    //     .app_websocket(new_app_id.clone(), holochain_client::AllowedOrigins::Any)
    //     .await
    //     .unwrap();

    // println!("Getting agent details of {}", app_ws.my_pub_key);
    // let profile: Option<AgentDetails> = app_ws
    //     .call_zome(
    //         holochain_client::ZomeCallTarget::RoleName("agent_details".into()),
    //         "agent_details".into(),
    //         "get_agent_details".into(),
    //         ExternIO::encode(app_ws.my_pub_key.clone()).unwrap(),
    //     )
    //     .await
    //     .map_err(|e| println!("Error: {:?}", e))
    //     .map(|r| r.decode().unwrap())
    //     .unwrap_or(None);

    // println!("profile: {:?}", profile);
    // assert!(profile.is_some());
    // assert_eq!(profile.unwrap().name, String::from("alice"))
}
