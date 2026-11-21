package it.akai.customremote;

import it.akai.customremote.ai.CloudVisionRequestPolicy;

public final class CloudVisionRequestPolicyTest {
    private static int assertions;
    private static final byte[] JPEG = new byte[256];
    static {
        JPEG[0]=(byte)0xff; JPEG[1]=(byte)0xd8;
        JPEG[JPEG.length-2]=(byte)0xff; JPEG[JPEG.length-1]=(byte)0xd9;
    }
    private static void check(boolean x, String what) {
        assertions++;
        if (!x) throw new AssertionError(what);
    }
    private static boolean accepted(String provider,String model,boolean os,boolean explicit,
                                    boolean context,boolean sensitive,int w,int h,byte[] bytes) {
        return CloudVisionRequestPolicy.inspect(provider, model, os, explicit, context,
                sensitive, w, h, bytes).allowed;
    }
    public static void main(String[] args) {
        check("deepseek-flash".equals(CloudVisionRequestPolicy.selectVisionModel("deepseek")), "flash model");
        check("kimi-k2.6".equals(CloudVisionRequestPolicy.selectVisionModel("kimi")), "k2.6 model");
        check(CloudVisionRequestPolicy.selectVisionModel("local") == null, "no local model");
        check(accepted("deepseek","deepseek-flash",true,true,true,false,960,540,JPEG), "DeepSeek consent");
        check(accepted("kimi","kimi-k2.6",true,true,true,false,960,540,JPEG), "Kimi consent");
        check(!accepted("local","local-model",true,true,true,false,960,540,JPEG), "local inference forbidden");
        check(!accepted("openai","gpt",true,true,true,false,960,540,JPEG), "third provider forbidden");
        check(!accepted("kimi","moonshot-v1-8k",true,true,true,false,960,540,JPEG), "text-only Kimi denied");
        check(!accepted("deepseek","deepseek-v4-pro",true,true,true,false,960,540,JPEG), "text-only DeepSeek denied");
        check(!accepted("deepseek","deepseek-flash",false,true,true,false,960,540,JPEG), "OS consent required");
        check(!accepted("deepseek","deepseek-flash",true,false,true,false,960,540,JPEG), "cloud consent required");
        check(!accepted("deepseek","deepseek-flash",true,true,false,false,960,540,JPEG), "context consent required");
        check(!accepted("deepseek","deepseek-flash",true,true,true,true,960,540,JPEG), "sensitive screen denied");
        check(!accepted("deepseek","deepseek-flash",true,true,true,false,961,540,JPEG), "width cap");
        check(!accepted("deepseek","deepseek-flash",true,true,true,false,960,541,JPEG), "height cap");
        check(!accepted("deepseek","deepseek-flash",true,true,true,false,0,540,JPEG), "zero dimension");
        check(!accepted("deepseek","deepseek-flash",true,true,true,false,960,540,null), "null data");
        byte[] invalid = JPEG.clone();invalid[0]=0;
        check(!accepted("deepseek","deepseek-flash",true,true,true,false,960,540,invalid), "JPEG header");
        invalid=JPEG.clone();invalid[invalid.length-1]=0;
        check(!accepted("deepseek","deepseek-flash",true,true,true,false,960,540,invalid), "JPEG footer");
        check(!accepted("deepseek","deepseek-flash",true,true,true,false,960,540,new byte[30]), "short image");
        byte[] huge=new byte[CloudVisionRequestPolicy.MAX_IMAGE_BYTES+1];
        huge[0]=(byte)0xff;huge[1]=(byte)0xd8;huge[huge.length-2]=(byte)0xff;huge[huge.length-1]=(byte)0xd9;
        check(!accepted("deepseek","deepseek-flash",true,true,true,false,960,540,huge), "image payload cap");
        System.out.println("CloudVisionRequestPolicyTest PASS: "+assertions+" checks, no upload.");
    }
}
