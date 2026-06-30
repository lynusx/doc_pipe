// LCS 行 diff，用于 dry-run 统计 inserts/deletes/modifies。

enum _EditOp { equal, insert, delete }

class LineDiffResult {
  final int inserts;
  final int deletes;
  final int modifies;

  const LineDiffResult({
    required this.inserts,
    required this.deletes,
    required this.modifies,
  });
}

/// 对 [oldLines] 和 [newLines] 做 LCS diff，统计插入/删除/修改行数。
///
/// 连续的 delete 块紧跟 insert 块时，按 1:1 配对计为 modify，
/// 超出配对长度的部分计为纯 insert 或 delete。
LineDiffResult diffLines(List<String> oldLines, List<String> newLines) {
  final ops = _lcsDiffOps(oldLines, newLines);

  int inserts = 0, deletes = 0, modifies = 0;
  int i = 0;
  while (i < ops.length) {
    if (ops[i] == _EditOp.equal) {
      i++;
      continue;
    }
    int delRun = 0, insRun = 0;
    while (i < ops.length && ops[i] == _EditOp.delete) {
      delRun++;
      i++;
    }
    while (i < ops.length && ops[i] == _EditOp.insert) {
      insRun++;
      i++;
    }
    final paired = delRun < insRun ? delRun : insRun;
    modifies += paired;
    deletes += delRun - paired;
    inserts += insRun - paired;
  }

  return LineDiffResult(inserts: inserts, deletes: deletes, modifies: modifies);
}

List<_EditOp> _lcsDiffOps(List<String> a, List<String> b) {
  final n = a.length, m = b.length;
  final lcs = List.generate(n + 1, (_) => List<int>.filled(m + 1, 0));
  for (int i = n - 1; i >= 0; i--) {
    for (int j = m - 1; j >= 0; j--) {
      lcs[i][j] = a[i] == b[j]
          ? lcs[i + 1][j + 1] + 1
          : (lcs[i + 1][j] > lcs[i][j + 1] ? lcs[i + 1][j] : lcs[i][j + 1]);
    }
  }

  final ops = <_EditOp>[];
  int i = 0, j = 0;
  while (i < n && j < m) {
    if (a[i] == b[j]) {
      ops.add(_EditOp.equal);
      i++;
      j++;
    } else if (lcs[i + 1][j] >= lcs[i][j + 1]) {
      ops.add(_EditOp.delete);
      i++;
    } else {
      ops.add(_EditOp.insert);
      j++;
    }
  }
  while (i < n) {
    ops.add(_EditOp.delete);
    i++;
  }
  while (j < m) {
    ops.add(_EditOp.insert);
    j++;
  }
  return ops;
}
