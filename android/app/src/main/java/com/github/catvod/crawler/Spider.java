package com.github.catvod.crawler;

import android.content.Context;

import java.util.HashMap;
import java.util.List;
import java.util.Map;

/**
 * TVBox Spider 插件基类。
 *
 * 运行时加载的 .jar 会继承本类并覆盖这些方法。签名必须与 TVBox 官方保持一致，
 * 否则插件里的类在 DexClassLoader 里找不到父类，报
 * "Class not found using the boot class loader"。
 */
public abstract class Spider {
    public String siteKey = "";

    public void init(Context context) throws Exception {
    }

    public void init(Context context, String extend) throws Exception {
        init(context);
    }

    public String homeContent(boolean filter) throws Exception {
        return "";
    }

    public String homeVideoContent() throws Exception {
        return "";
    }

    public String categoryContent(String tid, String pg, boolean filter, HashMap<String, String> extend) throws Exception {
        return "";
    }

    public String detailContent(List<String> ids) throws Exception {
        return "";
    }

    public String searchContent(String key, boolean quick) throws Exception {
        return "";
    }

    public String searchContent(String key, boolean quick, String pg) throws Exception {
        return searchContent(key, quick);
    }

    public String playerContent(String flag, String id, List<String> vipFlags) throws Exception {
        return "";
    }

    public boolean isVideoFormat(String url) throws Exception {
        return false;
    }

    public boolean manualVideoCheck() throws Exception {
        return false;
    }

    public Object[] proxyLocal(Map<String, String> params) throws Exception {
        return null;
    }

    public void destroy() {
    }
}
