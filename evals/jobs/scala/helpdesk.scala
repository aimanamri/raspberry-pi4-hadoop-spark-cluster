/*
 * IT helpdesk: tickets joined to agents.
 * Cleans bad dates, open tickets, closed before opened, satisfaction outside 1-5, duplicates. Writes:
 *   team_priority (resolution days and satisfaction), top_agents (top 10 by tickets),
 *   best_in_team (top 3 agents per team by satisfaction, window rank, at least 20 tickets).
 *
 * Input : <input>/helpdesk/<table>.csv   (spark.eval.input,  default hdfs:///evals)
 * Output: <output>/helpdesk/scala/<name>/  CSV with header (spark.eval.output, default hdfs:///evals-out)
 * Run   : spark-shell --master yarn -i helpdesk.scala --conf spark.eval.input=... --conf spark.eval.output=... < /dev/null
 *         (no compile step; spark-shell reads the file and exits. spark-shell runs in client mode only.)
 * Prints: one EVAL_SUMMARY line (same keys in the PySpark and R job), EVAL_HOSTS, EVAL_STATUS.
 */
import org.apache.spark.sql.DataFrame
import org.apache.spark.sql.expressions.Window
import org.apache.spark.sql.functions._

val IN  = spark.conf.get("spark.eval.input", "hdfs:///evals")
val OUT = spark.conf.get("spark.eval.output", "hdfs:///evals-out")
spark.conf.set("spark.sql.ansi.enabled", "false") // bad values become null instead of an error

def read(name: String): DataFrame = spark.read.option("header", "true").csv(s"$IN/helpdesk/$name.csv")
def save(df: DataFrame, name: String): Unit =
  df.coalesce(1).write.mode("overwrite").option("header", "true").csv(s"$OUT/helpdesk/scala/$name")
def fmt(d: Double, n: Int): String = String.format(java.util.Locale.ROOT, "%." + n + "f", Double.box(d))
def finish(parts: Int, kv: (String, Any)*): Unit = {
  // Hosts that run a Spark JVM for this application (the driver and the executors).
  val hosts = spark.sparkContext.getExecutorMemoryStatus.keys.map(_.split(":")(0)).toSeq.distinct.sorted.mkString(",")
  val lines = Seq(s"EVAL_SUMMARY domain=helpdesk lang=scala partitions=$parts " + kv.map { case (k, v) => s"$k=$v" }.mkString(" "),
    "EVAL_HOSTS " + hosts, "EVAL_STATUS OK")
  lines.foreach(println)
  import spark.implicits._
  lines.toDF("value").coalesce(1).write.mode("overwrite").text(s"$OUT/helpdesk/scala/summary") // kept for the runner
}

try {
val tk0 = read("tickets")
val raw = tk0.count(); val parts = tk0.rdd.getNumPartitions
val sat = col("satisfaction").cast("int")
val tk = tk0.dropDuplicates("ticket_id")
  .withColumn("opened_date", to_date(col("opened_date"), "yyyy-MM-dd"))
  .withColumn("closed_date", to_date(col("closed_date"), "yyyy-MM-dd"))
  .withColumn("satisfaction", when(sat.between(1, 5), sat))
  .filter(col("opened_date").isNotNull && col("closed_date").isNotNull && col("closed_date") >= col("opened_date"))
  .withColumn("res_days", datediff(col("closed_date"), col("opened_date")))
val df = tk.join(read("agents"), "agent_id")

save(df.groupBy("team", "priority")
  .agg(count("*").alias("tickets"), round(avg("res_days"), 2).alias("avg_res_days"), round(avg("satisfaction"), 2).alias("avg_satisfaction"))
  .orderBy("team", "priority"), "team_priority")
save(df.groupBy("agent_id", "team").agg(count("*").alias("tickets")).orderBy(desc("tickets"), col("agent_id")).limit(10), "top_agents")
val stats = df.groupBy("agent_id", "team").agg(count("*").alias("tickets"), avg("satisfaction").alias("avg_sat"))
  .filter(col("tickets") >= 20 && col("avg_sat").isNotNull)
  .withColumn("rank", row_number().over(Window.partitionBy("team").orderBy(desc("avg_sat"), col("agent_id"))))
  .filter(col("rank") <= 3).withColumn("avg_sat", round(col("avg_sat"), 3)).orderBy("team", "rank")
save(stats, "best_in_team")

finish(parts, "raw_rows" -> raw, "clean_rows" -> df.count(), "avg_resolution_days" -> fmt(df.agg(avg("res_days")).first.getDouble(0), 3),
  "sla_breaches" -> df.filter(col("res_days") > 5).count())
} catch {
  case e: Throwable => e.printStackTrace(); println("EVAL_STATUS FAIL"); sys.exit(1)
}
sys.exit(0)
