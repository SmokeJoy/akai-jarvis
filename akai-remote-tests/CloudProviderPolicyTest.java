package it.akai.customremote;

import it.akai.customremote.ai.CloudProviderPolicy;

public final class CloudProviderPolicyTest {
    private static int assertions = 0;
    private static void check(boolean condition, String description) {
        assertions++;
        if (!condition) throw new AssertionError(description);
    }

    public static void main(String[] args) {
        check(CloudProviderPolicy.isSupportedCloudProvider("deepseek"), "DeepSeek allowed");
        check(CloudProviderPolicy.isSupportedCloudProvider("kimi"), "Kimi allowed");
        check(!CloudProviderPolicy.isSupportedCloudProvider("openai"), "other cloud denied");
        check(!CloudProviderPolicy.isSupportedCloudProvider("ollama"), "local model denied");
        check(!CloudProviderPolicy.isSupportedCloudProvider("lmstudio"), "local inference denied");
        check(!CloudProviderPolicy.isSupportedCloudProvider("local"), "local commands are not a model provider");
        check(!CloudProviderPolicy.isSupportedCloudProvider(null), "null denied");

        String deepseek = "https://api.deepseek.com/chat/completions";
        String kimi = "https://api.moonshot.ai/v1/chat/completions";
        check(CloudProviderPolicy.isApprovedDestination("deepseek", deepseek), "DeepSeek official");
        check(CloudProviderPolicy.isApprovedDestination("kimi", kimi), "Kimi international");
        check(CloudProviderPolicy.isApprovedDestination("kimi",
                "https://api.moonshot.cn/v1/chat/completions"), "Kimi China");

        check(!CloudProviderPolicy.isApprovedDestination("deepseek", kimi), "DeepSeek key cannot reach Kimi");
        check(!CloudProviderPolicy.isApprovedDestination("kimi", deepseek), "Kimi key cannot reach DeepSeek");
        check(!CloudProviderPolicy.isApprovedDestination("local", deepseek), "local provider denied");
        check(!CloudProviderPolicy.isApprovedDestination("openai",
                "https://api.openai.com/v1/chat/completions"), "other provider denied");
        check(!CloudProviderPolicy.isApprovedDestination("deepseek",
                "http://api.deepseek.com/chat/completions"), "cleartext denied");
        check(!CloudProviderPolicy.isApprovedDestination("deepseek",
                "https://api.deepseek.com.evil.test/chat/completions"), "host suffix spoof denied");
        check(!CloudProviderPolicy.isApprovedDestination("deepseek",
                "https://api.deepseek.com@evil.test/chat/completions"), "userinfo spoof denied");
        check(!CloudProviderPolicy.isApprovedDestination("deepseek",
                "https://api.deepseek.com:8443/chat/completions"), "nonstandard port denied");
        check(!CloudProviderPolicy.isApprovedDestination("deepseek",
                "https://api.deepseek.com/other"), "path changed denied");
        check(!CloudProviderPolicy.isApprovedDestination("deepseek",
                "https://api.deepseek.com/chat/completions?token=secret"), "query denied");
        check(!CloudProviderPolicy.isApprovedDestination("deepseek",
                "https://api.deepseek.com/chat/completions#fragment"), "fragment denied");
        check(!CloudProviderPolicy.isApprovedDestination("kimi", null), "missing URL denied");
        check(CloudProviderPolicy.isLoopbackTestDestination("http://127.0.0.1:8080/v1/chat/completions"),
                "host mock allowed");
        check(!CloudProviderPolicy.isLoopbackTestDestination("http://192.168.1.108:8088/api"),
                "LAN endpoint not a fake AI provider");
        check(!CloudProviderPolicy.isLoopbackTestDestination("https://api.deepseek.com/chat/completions"),
                "production not test loopback");
        System.out.println("CloudProviderPolicyTest PASS: " + assertions + " checks; DeepSeek/Kimi only, no local LLM.");
    }
}
