package main

import (
	"flag"
	"time"

	"github.com/kevin-chtw/tw_db_svr/models"
	"github.com/natefinch/lumberjack"
	"github.com/sirupsen/logrus"
	"github.com/spf13/viper"
	"github.com/topfreegames/pitaya/v3/pkg/config"
	"gorm.io/driver/mysql"
	"gorm.io/gorm"
	"gorm.io/gorm/logger"
)

func InitMysql() *gorm.DB {
	var mysqlLogger logger.Interface
	db, err := gorm.Open(mysql.Open(viper.GetString("MySQL")), &gorm.Config{
		Logger: mysqlLogger,
	})
	if err != nil {
		logrus.Fatalf("gorm.Open err: %v", err)
	}

	sqlDB, err := db.DB()
	if err != nil {
		logrus.Fatalf("db.DB err: %v", err)
	}
	sqlDB.SetMaxIdleConns(10)
	sqlDB.SetMaxOpenConns(100)
	sqlDB.SetConnMaxLifetime(time.Hour * 4)

	return db
}

func InitGorm(MysqlDataSource string) *gorm.DB {
	db, err := gorm.Open(mysql.Open(MysqlDataSource), &gorm.Config{})
	if err != nil {
		logrus.Fatalf("连接mysql数据库失败，err:%v", err)
	} else {
		logrus.Info("连接mysql数据库成功")
	}
	return db
}

var configFile = flag.String("f", "../etc/db.yaml", "the config file")

func main() {
	flag.Parse()

	viper.SetConfigFile(*configFile)
	err := viper.ReadInConfig()
	if err != nil {
		logrus.Fatalf("Error reading config file: %v", err)
	}

	level, err := logrus.ParseLevel(viper.GetString("Logs.LogLevel"))
	if err != nil {
		logrus.Fatalf("Error parsing log level: %v", err)
	}

	logFile := viper.GetString("Logs.LogFile")
	// 设置日志输出到控制台和日志文件
	logrus.SetOutput(&lumberjack.Logger{
		Filename:   logFile, // 日志文件名
		MaxSize:    10,      // 每个日志文件保存的最大尺寸 单位：M
		MaxBackups: 3,       // 最多保留3个备份
		MaxAge:     28,      // 日志文件保留的最长天数
		Compress:   true,    // 是否压缩
	})
	logrus.SetLevel(level)

	db := InitMysql()
	err = db.AutoMigrate(
		&models.Player{},
	)
	if err != nil {
		logrus.Fatalf("AutoMigrate error: %v", err)
	}

	config := config.NewDefaultPitayaConfig()
	logrus.Infof("Pitaya server of type db started with config: %v", config)
	logrus.Info("Generate database models successfully")
}
