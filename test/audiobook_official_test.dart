import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:duanju_app/ui/audiobook/audiobook_fanqie.dart';

// 从 fanqie.apk 官方书城 tab_v2 真实回包裁剪的最小样本：一个 sub_cell
// 里同时有听书与普通小说（应被 genre=4 过滤），另一个单元格带官方分类。
const _sample = '''
{"code":0,"data":{"book_tab_infos":[{
  "tab_title":"推荐","tab_type":10,
  "cells":[
    {"name":"排行榜","show_type":241,"books":[],"sub_cells":[
      {"name":"推荐榜","books":[
        {"book_id":"7281195245084691518","book_name":"十日终焉","author":"杀虫队队员",
         "genre":"4","gender":"1","tags":"惊悚游戏,悬疑,推理","abstract":"当我以为这只是寻常的一天时",
         "audio_thumb_uri":"https://img.example/cover.jpg?sign=1",
         "category_info":"[{\\"ObjectId\\":537,\\"Dim\\":10,\\"Name\\":\\"惊悚游戏\\"},{\\"ObjectId\\":10,\\"Dim\\":1,\\"Name\\":\\"悬疑\\"}]",
         "score":"9.9"},
        {"book_id":"999","book_name":"普通小说","genre":"0","tags":"都市"}
      ]}
    ]},
    {"name":"热门标签","show_type":263,"books":[],
     "popular_tags":{"show_tags":[
       {"category_id":7,"name":"玄幻"},{"category_id":1,"name":"都市"}
     ]}}
  ]
}]}}
''';

Object? _decoded() => jsonDecode(_sample);

FanqieBook _book(String id, String category) => FanqieBook(
      id: id,
      title: '书$id',
      author: '作者',
      category: category,
    );

void main() {
  test('官方书城解析：只留听书、合并分类、抽热门标签', () {
    final page = fanqieOfficialPage(_decoded(), tabType: 10);
    expect(page.tabTitle, '推荐');
    expect(page.tabType, 10);
    expect(page.books, hasLength(1), reason: 'genre=0 的普通小说应被过滤');
    final book = page.books.single;
    expect(book.id, '7281195245084691518');
    expect(book.title, '十日终焉');
    expect(book.author, '杀虫队队员');
    expect(book.cover, 'https://img.example/cover.jpg?sign=1');
    expect(book.category, '惊悚游戏 · 悬疑 · 推理');
    expect(book.board, 0, reason: 'gender=1 归男生榜');
    expect(page.hotTags, ['玄幻', '都市']);
    for (final name in ['玄幻', '都市', '惊悚游戏', '悬疑']) {
      expect(page.categoryDims.containsKey(name), isTrue, reason: '缺 $name');
    }
    // 热门标签 Dim=0，主类 Dim=1，细分类 Dim=10。
    expect(page.categoryDims['都市'], 0);
    expect(page.categoryDims['悬疑'], 1);
    expect(page.categoryDims['惊悚游戏'], 10);
  });

  test('官方书城空回包 / 异常结构不炸', () {
    final page = fanqieOfficialPage({'code': 4000, 'data': {}});
    expect(page.books, isEmpty);
    expect(page.hotTags, isEmpty);
    expect(page.categoryDims, isEmpty);
  });

  test('officialAll 按 tab_type 并发取数、累积去重', () async {
    final urls = <String>[];
    final api = FanqieAudiobookApi(fetcher: (url) async {
      urls.add(url);
      return _sample;
    });
    final result = await api.officialAll(rounds: 2);
    expect(urls.length, 2 * novelfmTabTypes.length);
    for (final tab in novelfmTabTypes) {
      expect(
        urls.where((url) => url.contains('tab_type=$tab')).length,
        2,
        reason: 'tab_type=$tab 应请求两轮',
      );
    }
    expect(urls.first, contains('aid=3040'));
    expect(urls.first, contains('update_version_code=1'));
    // 每轮回包都一样，按 book_id 去重后仍只有 1 本。
    expect(result.books, hasLength(1));
    expect(result.tabs, ['推荐']);
    expect(result.hotTags, ['玄幻', '都市']);
    expect(result.categories, contains('惊悚游戏'));
    // 排序：Dim 小的在前，玄幻/都市(0) 早于悬疑(1) 早于惊悚游戏(10)。
    expect(
      result.categories.indexOf('玄幻'),
      lessThan(result.categories.indexOf('惊悚游戏')),
    );
  });

  test('官方源失败时退化为不补充书目，不影响榜单', () async {
    final api = FanqieAudiobookApi(fetcher: (_) async => throw 'offline');
    final result = await api.officialAll(rounds: 1);
    expect(result.books, isEmpty);
    expect(result.categories, isEmpty);
  });

  test('分类只展示书池里有书的，并补上官方实时学到的分类', () {
    final pool = [
      _book('1', '都市 · 系统'),
      _book('2', '玄幻，穿越'),
      _book('3', '冷门标签'),
      _book('4', '惊悚游戏'),
    ];
    final categories = fanqieCategoriesFrom(
      pool,
      preferred: const ['惊悚游戏', '民俗秘闻'],
    );
    expect(categories, contains('都市'));
    expect(categories, contains('玄幻'));
    expect(categories, contains('惊悚游戏'), reason: '官方新分类应能出现');
    expect(categories, isNot(contains('冷门标签')));
    expect(categories, isNot(contains('民俗秘闻')), reason: '没书的分类不展示');
  });
}
