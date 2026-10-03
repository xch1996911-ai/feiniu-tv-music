/// 项目自维护的拼音短语词典。
///
/// ## 为什么需要它
///
/// 内置字库（`pinyin` 包）只保证**单字**的常见读音，短语表虽然很大
/// （约 4 万条，含「重庆」「重来」这类），但**歌手名、歌名、地名简称
/// 基本不在其中**。实测：
/// - ✅ 内置有：`重庆` `重来` `音乐` `乐队`
/// - ❌ 内置没有：`长沙` `单依纯` `曾轶可` `解晓东` `周杰伦` `那英` `朴树`
///
/// 需求（拼音模糊搜索 §4）明确要求：
/// 「引入必要的开源拼音引擎，或项目内维护一份精简词典……
///   项目内维护的小词典必须能覆盖常见多音字词组（如"重庆""长沙""单依纯"等），
///   并易于后续扩充」。
///
/// ## 格式与扩充方式
///
/// 每条形如 `'词组=拼音1,拼音2,...'`，**必须满足**：
/// 1. 词组用**简体**（索引侧会先把繁体字段转成简体再查表）；
/// 2. 拼音**不带声调**、全小写、`ü` 写成 `v`（与 `pinyin` 包的输出一致）；
/// 3. 拼音个数**必须等于**词组的字数 ——
///    对不上时 `PinyinService` 会整条忽略并退回逐字转换，
///    绝不会因为词典写错而让某一首歌的索引整体错位。
///
/// 新增一条只需要在 [_entries] 对应分组里加一行，
/// `pinyin_lexicon_test.dart` 会自动校验上面三条约束。
class PinyinLexicon {
  PinyinLexicon._();

  /// 词典版本。参与搜索索引缓存的失效判定（见 `SearchIndexStore`）。
  static const int version = 1;

  /// 多音字词组表。
  ///
  /// 分组只是为了便于维护，运行时是一张平表。
  static const Map<String, String> entries = <String, String>{
    // ── 姓氏（读法与人名/日常读音不同，最容易搜不到）──────────────
    '单依纯': 'shan,yi,chun', // 单 作姓氏读 shàn
    '单田芳': 'shan,tian,fang',
    '单县': 'shan,xian',
    '曾轶可': 'zeng,yi,ke', // 曾 作姓氏读 zēng
    '曾毅': 'zeng,yi',
    '曾志伟': 'zeng,zhi,wei',
    '解晓东': 'xie,xiao,dong', // 解 作姓氏读 xiè
    '任贤齐': 'ren,xian,qi', // 任 作姓氏读 rén
    '那英': 'na,ying', // 那 作姓氏读 nā
    '华晨宇': 'hua,chen,yu',
    '乐嘉': 'yue,jia', // 乐 作姓氏读 yuè
    '朴树': 'pu,shu',
    '缪杰': 'miao,jie',
    '仇英': 'qiu,ying',
    '查良镛': 'zha,liang,yong',
    '燕姿': 'yan,zi',
    '孙燕姿': 'sun,yan,zi',
    '沈腾': 'shen,teng',
    '周杰伦': 'zhou,jie,lun',

    // ── 地名（多音字地名是典型"搜不到"的场景）──────────────────
    '重庆': 'chong,qing',
    '长沙': 'chang,sha',
    '长春': 'chang,chun',
    '长城': 'chang,cheng',
    '长江': 'chang,jiang',
    '厦门': 'xia,men',
    '蚌埠': 'beng,bu',
    '亳州': 'bo,zhou',
    '六安': 'lu,an',
    '涪陵': 'fu,ling',
    '郫县': 'pi,xian',
    '犍为': 'qian,wei',
    '婺源': 'wu,yuan',
    '铅山': 'yan,shan',
    '番禺': 'pan,yu',
    '丽水': 'li,shui',
    '蔚县': 'yu,xian',
    '台州': 'tai,zhou',
    '秘鲁': 'bi,lu',
    '龟兹': 'qiu,ci',
    '吐蕃': 'tu,bo',
    '柏林': 'bo,lin',
    '华阴': 'hua,yin',
    '乐亭': 'lao,ting',
    '都江堰': 'du,jiang,yan',
    '洪洞': 'hong,tong',
    '吴堡': 'wu,bu',
    '监利': 'jian,li',
    '尉犁': 'yu,li',
    '宁蒗': 'ning,lang',
    '鄄城': 'juan,cheng',
    '牟平': 'mu,ping',
    '鸭绿江': 'ya,lu,jiang',
    '朝阳区': 'chao,yang,qu',
    '阿房宫': 'e,fang,gong',
    '单曲循环': 'dan,qu,xun,huan',

    // ── 音乐场景高频词（曲库里每天都在出现）────────────────────
    '音乐': 'yin,yue',
    '乐队': 'yue,dui',
    '乐器': 'yue,qi',
    '乐曲': 'yue,qu',
    '乐章': 'yue,zhang',
    '乐趣': 'le,qu',
    '歌曲': 'ge,qu',
    '曲目': 'qu,mu',
    '曲子': 'qu,zi',
    '曲调': 'qu,diao',
    '单曲': 'dan,qu',
    '专辑': 'zhuan,ji',
    '合辑': 'he,ji',
    '弹奏': 'tan,zou',
    '弹唱': 'tan,chang',
    '吉他': 'ji,ta',
    '钢琴': 'gang,qin',
    '弦乐': 'xian,yue',
    '打击乐': 'da,ji,yue',
    '交响乐': 'jiao,xiang,yue',
    '民乐': 'min,yue',
    '声乐': 'sheng,yue',
    '器乐': 'qi,yue',
    '管弦乐': 'guan,xian,yue',

    // ── 通用多音字（第二大失分点）────────────────────────────
    '重要': 'zhong,yao',
    '重新': 'chong,xin',
    '重复': 'chong,fu',
    '重叠': 'chong,die',
    '重逢': 'chong,feng',
    '重阳': 'chong,yang',
    '重生': 'chong,sheng',
    '重量': 'zhong,liang',
    '成长': 'cheng,zhang',
    '长大': 'zhang,da',
    '长相': 'zhang,xiang',
    '长者': 'zhang,zhe',
    '行长': 'hang,zhang',
    '生长': 'sheng,zhang',
    '校长': 'xiao,zhang',
    '家长': 'jia,zhang',
    '成长记': 'cheng,zhang,ji',
    '曾经': 'ceng,jing',
    '快乐': 'kuai,le',
    '娱乐': 'yu,le',
    '乐园': 'le,yuan',
    '欢乐': 'huan,le',
    '行走': 'xing,zou',
    '行李': 'xing,li',
    '行星': 'xing,xing',
    '行囊': 'xing,nang',
    '旅行': 'lv,xing',
    '银行': 'yin,hang',
    '行业': 'hang,ye',
    '排行': 'pai,hang',
    '内行': 'nei,hang',
    '解放': 'jie,fang',
    '解散': 'jie,san',
    '解答': 'jie,da',
    '押解': 'ya,jie',
    '模样': 'mu,yang',
    '模型': 'mo,xing',
    '债券': 'zhai,quan',
    '证券': 'zheng,quan',
    '弹琴': 'tan,qin',
    '子弹': 'zi,dan',
    '炮弹': 'pao,dan',
    '曲折': 'qu,zhe',
    '弯曲': 'wan,qu',
    '调查': 'diao,cha',
    '调色': 'tiao,se',
    '声调': 'sheng,diao',
    '湖泊': 'hu,po',
    '血泊': 'xue,po',
    '记载': 'ji,zai',
    '下载': 'xia,zai',
    '装载': 'zhuang,zai',
    '答应': 'da,ying',
    '回答': 'hui,da',
    '逮捕': 'dai,bu',
    '恶劣': 'e,lie',
    '恶心': 'e,xin',
    '薄弱': 'bo,ruo',
    '薄荷': 'bo,he',
    '单薄': 'dan,bo',
    '计划': 'ji,hua',
    '划分': 'hua,fen',
    '划船': 'hua,chuan',
    '裂缝': 'lie,feng',
    '缝补': 'feng,bu',
    '缝隙': 'feng,xi',
    '给予': 'ji,yu',
    '送给': 'song,gei',
    '处理': 'chu,li',
    '处境': 'chu,jing',
    '到处': 'dao,chu',
    '参加': 'can,jia',
    '人参': 'ren,shen',
    '参差': 'cen,ci',
    '差别': 'cha,bie',
    '出差': 'chu,chai',
    '差劲': 'cha,jin',
    '刹那': 'cha,na',
    '宿舍': 'su,she',
    '房舍': 'fang,she',
    '舍弃': 'she,qi',
    '刹车': 'sha,che',
    '打折': 'da,zhe',
    '折腾': 'zhe,teng',
    '折磨': 'zhe,mo',
    '磨难': 'mo,nan',
    '磨损': 'mo,sun',
    '撒哈拉': 'sa,ha,la',
    '播撒': 'bo,sa',
    '数码': 'shu,ma',
    '数量': 'shu,liang',
    '数落': 'shu,luo',
    '惩罚': 'cheng,fa',
    '乘凉': 'cheng,liang',
    '宝藏': 'bao,zang',
    '西藏': 'xi,zang',
    '藏族': 'zang,zu',
    '收藏': 'shou,cang',
    '躲藏': 'duo,cang',
    '朝气': 'zhao,qi',
    '朝代': 'chao,dai',
    '朝鲜': 'chao,xian',
    '号码': 'hao,ma',
    '呼号': 'hu,hao',
    '绿色': 'lv,se',
    '绿林': 'lu,lin',
    '露出': 'lu,chu',
    '露天': 'lu,tian',
    '露水': 'lu,shui',
    '分量': 'fen,liang',
    '分外': 'fen,wai',
    '部分': 'bu,fen',
    '强迫': 'qiang,po',
    '强大': 'qiang,da',
    '勉强': 'mian,qiang',
    '倔强': 'jue,jiang',
    '相处': 'xiang,chu',
    '相互': 'xiang,hu',
    '相貌': 'xiang,mao',
    '相机': 'xiang,ji',
    '血液': 'xue,ye',
    '血型': 'xue,xing',
    '系统': 'xi,tong',
    '关系': 'guan,xi',
    '兴奋': 'xing,fen',
    '高兴': 'gao,xing',
    '兴旺': 'xing,wang',
    '兴趣': 'xing,qu',
    '宿命': 'su,ming',
    '星宿': 'xing,xiu',
    '钥匙': 'yao,shi',
    '汤匙': 'tang,chi',
    '阿姨': 'a,yi',
    '大臣': 'da,chen',
    '便宜': 'pian,yi',
    '方便': 'fang,bian',
    '单位': 'dan,wei',
    '单身': 'dan,shen',
    '名单': 'ming,dan',
    '简单': 'jian,dan',
    '孤单': 'gu,dan',
    '禅宗': 'chan,zong',
    '传记': 'zhuan,ji',
    '传说': 'chuan,shuo',
    '水浒传': 'shui,hu,zhuan',
    '号角': 'hao,jiao',
    '一宿': 'yi,xiu',

    // ── 歌名常见词（保证 "qlx" "gabqq" 这类首字母能命中）─────────
    '七里香': 'qi,li,xiang',
    '告白气球': 'gao,bai,qi,qiu',
    '龙卷风': 'long,juan,feng',
    '借口': 'jie,kou',
    '暗号': 'an,hao',
    '青花瓷': 'qing,hua,ci',
    '稻香': 'dao,xiang',
    '花海': 'hua,hai',
    '烟花易冷': 'yan,hua,yi,leng',
    '好久不见': 'hao,jiu,bu,jian',
    '听见下雨的声音': 'ting,jian,xia,yu,de,sheng,yin',
    '一路向北': 'yi,lu,xiang,bei',
    '我的地盘': 'wo,de,di,pan',
    '珊瑚海': 'shan,hu,hai',
    '不能说的秘密': 'bu,neng,shuo,de,mi,mi',
    '兰亭序': 'lan,ting,xu',
    '蒲公英的约定': 'pu,gong,ying,de,yue,ding',
    '等你下课': 'deng,ni,xia,ke',
    '说好的幸福呢': 'shuo,hao,de,xing,fu,ne',
    '给我一首歌的时间': 'gei,wo,yi,shou,ge,de,shi,jian',
    '小幸运': 'xiao,xing,yun',
    '夜空中最亮的星': 'ye,kong,zhong,zui,liang,de,xing',
    '平凡之路': 'ping,fan,zhi,lu',
    '成都': 'cheng,du',
    '南方姑娘': 'nan,fang,gu,niang',
    '董小姐': 'dong,xiao,jie',
    '斑马斑马': 'ban,ma,ban,ma',
    '安和桥': 'an,he,qiao',
    '蓝色土耳其': 'lan,se,tu,er,qi',
    '童话镇': 'tong,hua,zhen',
  };

  /// 词典中最长的词组长度（用于限制最长匹配的起点）。
  ///
  /// 由 [entries] 推导，不写死常量 —— 加条目时不怕忘记同步。
  static int get longestPhraseLength {
    int max = 1;
    for (final String w in entries.keys) {
      final int n = w.runes.length;
      if (n > max) max = n;
    }
    return max;
  }
}
